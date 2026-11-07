// このファイルは Tools/embed_runtime.sh が Sources/GameCompiler/Runtime/gm_runtime.c から作る。直接編集しない。

enum RuntimeSource {
    static let text = #"""
// GAME-M4 のランタイム。コンパイルした GAME のプログラムとリンクする。
//
// 出力、行の入力と `?` の式の評価、乱数、割り算、第 2 スタック、行の表の検索、端末の設定を持つ。
// 動きは GameCore の Interpreter(GAME65G の移植)に合わせる。設計書 §9。
// 仮想メモリの番地は GAME65G と同じ(変数 $80、余り $08、先頭 $0A、末尾 $0C、RAM 末尾 $0E、乱数 $10)。

#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define REM_ADDR    0x08
#define PSTART_ADDR 0x0A
#define PEND_ADDR   0x0C
#define RAMEND_ADDR 0x0E
#define RNDV_ADDR   0x10
#define VARS_ADDR   0x80
#define INBUF       0x0480
#define PROG        0x0600
#define STACK_MAX   31

typedef struct {
    int32_t number;
    int32_t pad;
    void *addr;
} gm_entry;

typedef struct {
    void *resume;
    int32_t line;
    uint16_t end;
} gm_frame;

// 生成したコードから見る値
int32_t gm_line;                    // 実行中の行番号
_Atomic int32_t gm_flag;            // 1: Ctrl-C が届いた、2: 出力を書き出す時刻
uint8_t gm_mem[0x10000];            // 仮想メモリ

static const gm_entry *table;
static int table_count;
static gm_frame stack[STACK_MAX];
static int sp;

// ---- 出力 ----

static uint8_t outbuf[4096];
static _Atomic int outlen;
static int col0 = 1;
static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static void flush_out(void) {
    pthread_mutex_lock(&out_lock);
    int n = outlen;
    int off = 0;
    while (off < n) {
        ssize_t w = write(STDOUT_FILENO, outbuf + off, (size_t)(n - off));
        if (w <= 0) break;
        off += (int)w;
    }
    outlen = 0;
    pthread_mutex_unlock(&out_lock);
}

static void out(uint8_t c) {
    if (outlen >= (int)sizeof(outbuf)) flush_out();
    outbuf[outlen] = c;
    outlen = outlen + 1;
    col0 = (c == 0x0A);
    if (c == 0x0A) flush_out();
}

void gm_crlf(void) {
    out(0x0D);
    out(0x0A);
}

static void out_str(const char *s) {
    while (*s) out((uint8_t)*s++);
}

// ---- 入力 ----

static pthread_mutex_t in_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t in_cond = PTHREAD_COND_INITIALIZER;
static uint8_t *inbuf;
static size_t in_head, in_tail, in_cap;
static int in_breaks;
static int in_closed;
static int in_primed;               // 起動時に届いていた入力を読み終えた
static int is_tty;
static struct termios original_tio;

static void restore_terminal(void) {
    if (is_tty) {
        tcsetattr(STDIN_FILENO, TCSANOW, &original_tio);
        is_tty = 0;
    }
}

static void in_append(uint8_t b) {
    pthread_mutex_lock(&in_lock);
    if (in_tail == in_cap) {
        if (in_head > 0) {
            memmove(inbuf, inbuf + in_head, in_tail - in_head);
            in_tail -= in_head;
            in_head = 0;
        }
        if (in_tail == in_cap) {
            in_cap = in_cap ? in_cap * 2 : 4096;
            inbuf = realloc(inbuf, in_cap);
        }
    }
    inbuf[in_tail++] = b;
    if (b == 0x03) {
        in_breaks++;
        atomic_fetch_or(&gm_flag, 1);
    }
    pthread_cond_broadcast(&in_cond);
    pthread_mutex_unlock(&in_lock);
}

static void set_primed(void) {
    pthread_mutex_lock(&in_lock);
    in_primed = 1;
    pthread_cond_broadcast(&in_cond);
    pthread_mutex_unlock(&in_lock);
}

static void *reader_main(void *arg) {
    (void)arg;
    int tty = isatty(STDIN_FILENO);
    int last_cr = 0;
    uint8_t b;
    for (;;) {
        if (!in_primed) {
            // すぐ読める入力がなくなったら、起動の待ちを解く(ファイルなら最後まで読んでから)
            struct pollfd p = {STDIN_FILENO, POLLIN, 0};
            if (poll(&p, 1, 0) == 0) set_primed();
        }
        if (read(STDIN_FILENO, &b, 1) != 1) break;
        if (tty && (b == 0x1C || b == 0x04)) break;   // Ctrl-\ と Ctrl-D は入力の終わり
        // 行末を CR にそろえる(CR LF は CR 1 つ、LF だけなら CR)
        if (b == 0x0A) {
            if (!last_cr) in_append(0x0D);
            last_cr = 0;
            continue;
        }
        last_cr = (b == 0x0D);
        in_append(b);
    }
    pthread_mutex_lock(&in_lock);
    in_closed = 1;
    in_primed = 1;
    pthread_cond_broadcast(&in_cond);
    pthread_mutex_unlock(&in_lock);
    return NULL;
}

// 出力がたまっていれば、20 ミリ秒ごとに書き出すよう知らせる
static void *ticker_main(void *arg) {
    (void)arg;
    struct timespec ts = {0, 20 * 1000 * 1000};
    for (;;) {
        nanosleep(&ts, NULL);
        if (outlen > 0) atomic_fetch_or(&gm_flag, 2);
    }
    return NULL;
}

// 1 バイト読む。wait なら届くまで待つ。なければ(入力の終わりも) -1。
static int in_read(int wait) {
    pthread_mutex_lock(&in_lock);
    while (in_head == in_tail) {
        if (!wait || in_closed) {
            pthread_mutex_unlock(&in_lock);
            return -1;
        }
        pthread_cond_wait(&in_cond, &in_lock);
    }
    uint8_t b = inbuf[in_head++];
    if (b == 0x03) {
        in_breaks--;
        if (in_breaks == 0) atomic_fetch_and(&gm_flag, ~1);
    }
    pthread_mutex_unlock(&in_lock);
    return b;
}

// 入力に Ctrl-C があれば、それまでの入力とともに取り除いて 1 を返す
static int take_break(void) {
    pthread_mutex_lock(&in_lock);
    int hit = 0;
    if (in_breaks > 0) {
        while (in_head < in_tail) {
            uint8_t b = inbuf[in_head++];
            if (b == 0x03) {
                in_breaks--;
                break;
            }
        }
        if (in_breaks == 0) atomic_fetch_and(&gm_flag, ~1);
        hit = 1;
    }
    pthread_mutex_unlock(&in_lock);
    return hit;
}

// ---- 終了 ----

static void finish(int code) {
    flush_out();
    restore_terminal();
    _exit(code);
}

static void print_decimal(uint16_t value, int width);

static void report(const char *msg, int code) {
    if (!col0) gm_crlf();
    out_str(msg);
    out(' ');
    print_decimal((uint16_t)gm_line, 0);
    gm_crlf();
    finish(code);
}

static void gm_error(void) {
    report("ERR", 1);
}

static void gm_brk(void) {
    report("BRK", 130);
}

void gm_end(void) {
    if (!col0) gm_crlf();
    finish(0);
}

// 行の頭で gm_flag が 0 以外のときに呼ぶ
void gm_poll(void) {
    if (atomic_fetch_and(&gm_flag, ~2) & 2) flush_out();
    if (take_break()) gm_brk();
}

// ---- 起動 ----

static uint16_t peek_word(uint16_t a) {
    return (uint16_t)(gm_mem[a] | gm_mem[(uint16_t)(a + 1)] << 8);
}

static void poke_word(uint16_t a, uint16_t v) {
    gm_mem[a] = (uint8_t)v;
    gm_mem[(uint16_t)(a + 1)] = (uint8_t)(v >> 8);
}

uint8_t *gm_start(const uint8_t *image, int len, const gm_entry *tab, int count) {
    table = tab;
    table_count = count;
    memcpy(gm_mem + PROG, image, (size_t)len);
    poke_word(PSTART_ADDR, PROG);
    poke_word(PEND_ADDR, (uint16_t)(PROG + len - 1));
    poke_word(RAMEND_ADDR, 0x7FFF);
    poke_word(RNDV_ADDR, 0xACE1);
    gm_line = 0;
    if (isatty(STDIN_FILENO)) {
        tcgetattr(STDIN_FILENO, &original_tio);
        struct termios raw = original_tio;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        is_tty = 1;
    }
    pthread_t t;
    pthread_create(&t, NULL, reader_main, NULL);
    pthread_detach(t);
    // 起動したときに届いていた入力は、読み終えてから始める(実行のたびに結果が変わらないように)
    pthread_mutex_lock(&in_lock);
    while (!in_primed) pthread_cond_wait(&in_cond, &in_lock);
    pthread_mutex_unlock(&in_lock);
    pthread_create(&t, NULL, ticker_main, NULL);
    pthread_detach(t);
    return gm_mem;
}

// ---- 表示 ----

static void print_decimal(uint16_t value, int width) {
    uint8_t digits[8];
    int n = 0;
    uint16_t v = value;
    int negative = (v & 0x8000) != 0;
    if (negative) v = (uint16_t)(0 - v);
    do {
        digits[n++] = (uint8_t)('0' + v % 10);
        v /= 10;
    } while (v != 0);
    if (negative) digits[n++] = '-';
    for (int w = width; w > n; w--) out(' ');
    while (n > 0) out(digits[--n]);
}

void gm_prnum(int value, int width) {
    print_decimal((uint16_t)value, width & 0xFF);
}

static void hex2(uint8_t v) {
    static const char digits[] = "0123456789ABCDEF";
    out((uint8_t)digits[v >> 4]);
    out((uint8_t)digits[v & 0x0F]);
}

void gm_hex4(int value) {
    hex2((uint8_t)(value >> 8));
    hex2((uint8_t)value);
}

void gm_hex2(int value) {
    hex2((uint8_t)value);
}

void gm_putc(int value) {
    out((uint8_t)value);
}

void gm_tab(int value) {
    for (int n = value & 0xFF; n > 0; n--) out(' ');
}

void gm_str(const char *s) {
    out_str(s);
}

// ---- 演算 ----

int gm_div(int a, int b) {
    int32_t x = (int16_t)a;
    int32_t y = (int16_t)b;
    if (y == 0) gm_error();
    poke_word(REM_ADDR, (uint16_t)(x % y));
    return (uint16_t)(x / y);
}

int gm_rnd(int value) {
    uint16_t n = (uint16_t)value;
    if (n == 0) return 0;
    uint16_t x = peek_word(RNDV_ADDR);
    if (x == 0) x = 1;
    x ^= (uint16_t)(x << 7);
    x ^= (uint16_t)(x >> 9);
    x ^= (uint16_t)(x << 8);
    poke_word(RNDV_ADDR, x);
    return x % n + 1;
}

// ---- 第 2 スタックと行の表 ----

void gm_push(void *resume, int end) {
    if (sp >= STACK_MAX) gm_error();
    stack[sp].resume = resume;
    stack[sp].line = gm_line;
    stack[sp].end = (uint16_t)end;
    sp++;
}

void *gm_ret(void) {
    if (sp == 0) gm_error();
    sp--;
    gm_line = stack[sp].line;
    return stack[sp].resume;
}

// NEXT と UNTIL。終値 < 値(符号付き)ならループを抜けて NULL、そうでなければ戻る先
void *gm_next(int value) {
    if (sp == 0) gm_error();
    gm_frame *top = &stack[sp - 1];
    if ((int16_t)top->end < (int16_t)value) {
        sp--;
        return NULL;
    }
    gm_line = top->line;
    return top->resume;
}

// 番号が target 以上(符号なし)の最初の行のコードの番地。なければ NULL
void *gm_find(int target) {
    uint16_t t = (uint16_t)target;
    for (int i = 0; i < table_count; i++) {
        if ((uint16_t)table[i].number >= t) return table[i].addr;
    }
    return NULL;
}

void *gm_gosub(void *resume, int target) {
    gm_push(resume, target);
    return gm_find(target);
}

// ---- 入力 ----

int gm_key(void) {
    int c = in_read(0);
    if (c == 0x03) gm_brk();
    if (c < 0) {
        // 入力が終わり、読み残しもなければ、空回りせずに終える(パイプやファイルから読むとき)
        pthread_mutex_lock(&in_lock);
        int exhausted = in_closed && in_head == in_tail;
        pthread_mutex_unlock(&in_lock);
        if (exhausted) gm_end();
        return 0;
    }
    return c;
}

// 文字列と注釈の外の小文字を大文字にする
static void upcase(uint16_t buf) {
    uint16_t y = buf;
    while (gm_mem[y] == ' ') y++;
    int saw_digit = 0;
    while (gm_mem[y] >= '0' && gm_mem[y] <= '9') {
        y++;
        saw_digit = 1;
    }
    if (saw_digit) {
        uint8_t c = gm_mem[y];
        if (c != ' ' && c != 0x0D && c != '/') return;
    }
    int quoted = 0;
    while (gm_mem[y] != 0x0D) {
        uint8_t c = gm_mem[y];
        if (c == '"') {
            quoted = !quoted;
        } else if (!quoted && c >= 'a' && c <= 'z') {
            gm_mem[y] = c & 0xDF;
        }
        y++;
    }
}

static void get_line(uint16_t buf) {
    uint16_t y = 0;
    for (;;) {
        int c = in_read(1);
        if (c < 0) gm_end();                       // 入力の終わり
        if (c == 0x0D) break;
        if (c == 0x03) gm_brk();
        if (c == 0x08 || c == 0x7F) {
            if (y > 0) {
                y--;
                out(0x08);
                out(' ');
                out(0x08);
            }
            continue;
        }
        if (c < 0x20 || y >= 120) continue;
        gm_mem[(uint16_t)(buf + y)] = (uint8_t)c;
        out((uint8_t)c);
        y++;
    }
    gm_mem[(uint16_t)(buf + y)] = 0x0D;
    gm_crlf();
    flush_out();
    upcase(buf);
}

// `?` で入力した行を、インタプリタの TERM と EXPR と同じ規則で評価する
static uint16_t tp;

static uint8_t getc_tp(void) { return gm_mem[tp]; }
static void inctp(void) { tp++; }
static uint8_t nextc(void) { tp++; return gm_mem[tp]; }
static int is_alpha(uint8_t c) { return c >= 'A' && c <= 'Z'; }
static int is_digit(uint8_t c) { return c >= '0' && c <= '9'; }
static int is_hex(uint8_t c) { return is_digit(c) || (c >= 'A' && c <= 'F'); }

static int var_addr(uint8_t c) {
    if (is_alpha(c)) return VARS_ADDR + (c - 'A') * 2;
    switch (c) {
    case '=': return PSTART_ADDR;
    case '&': return PEND_ADDR;
    case '*': return RAMEND_ADDR;
    case '\'': return RNDV_ADDR;
    default: return -1;
    }
}

static uint8_t skip_var(void) {
    uint8_t first = getc_tp();
    uint8_t c = nextc();
    if (is_alpha(first)) {
        while (is_alpha(c)) c = nextc();
    }
    return c;
}

static uint16_t expr(void);

static void expect_rparen(void) {
    if (getc_tp() != ')') gm_error();
    inctp();
}

static uint16_t array_address(int v, int word) {
    uint16_t base = peek_word((uint16_t)v);
    uint16_t index = expr();
    expect_rparen();
    return (uint16_t)(base + (word ? (uint16_t)(index << 1) : index));
}

int gm_input(void);

static uint16_t term(void) {
    uint8_t c = getc_tp();
    switch (c) {
    case '(': {
        inctp();
        uint16_t v = expr();
        expect_rparen();
        return v;
    }
    case '-':
        inctp();
        return (uint16_t)(0 - term());
    case '$': {
        uint8_t n = nextc();
        if (!is_hex(n)) return (uint16_t)gm_key();
        uint16_t v = 0;
        while (is_hex(getc_tp())) {
            uint8_t d = getc_tp();
            v = (uint16_t)(v << 4 | (d >= 'A' ? d - 0x37 : (d & 0x0F)));
            inctp();
        }
        return v;
    }
    case '?':
        inctp();
        return (uint16_t)gm_input();
    case '%':
        inctp();
        term();
        return peek_word(REM_ADDR);
    case '\'':
        inctp();
        return (uint16_t)gm_rnd(term());
    default:
        break;
    }
    if (is_digit(c)) {
        uint16_t v = 0;
        while (is_digit(getc_tp())) {
            v = (uint16_t)(v * 10 + (getc_tp() & 0x0F));
            inctp();
        }
        return v;
    }
    int v = var_addr(c);
    if (v < 0) gm_error();
    uint8_t n = skip_var();
    if (n == '(') {
        inctp();
        return peek_word(array_address(v, 1));
    }
    if (n == ':') {
        inctp();
        return gm_mem[array_address(v, 0)];
    }
    return peek_word((uint16_t)v);
}

static uint16_t expr(void) {
    uint16_t acc = term();
    for (;;) {
        uint8_t c = getc_tp();
        if (!strchr("+-*/&.!=<>", c) || c == 0) return acc;
        uint8_t next = nextc();
        char op = (char)c;
        if (c == '<') {
            if (next == '>') { op = 'n'; inctp(); }
            else if (next == '=') { op = 'l'; inctp(); }
        } else if (c == '>' && next == '=') {
            op = 'g';
            inctp();
        }
        uint16_t a = acc;
        uint16_t b = term();
        int16_t sa = (int16_t)a, sb = (int16_t)b;
        switch (op) {
        case '+': acc = (uint16_t)(a + b); break;
        case '-': acc = (uint16_t)(a - b); break;
        case '*': acc = (uint16_t)(a * b); break;
        case '/': acc = (uint16_t)gm_div(a, b); break;
        case '&': acc = a & b; break;
        case '.': acc = a | b; break;
        case '!': acc = a ^ b; break;
        case '=': acc = a == b; break;
        case 'n': acc = a != b; break;
        case '<': acc = sa < sb; break;
        case '>': acc = sa > sb; break;
        case 'l': acc = sa <= sb; break;
        case 'g': acc = sa >= sb; break;
        }
    }
}

int gm_input(void) {
    uint16_t saved = tp;
    get_line(INBUF);
    tp = INBUF;
    while (getc_tp() == ' ') inctp();
    uint16_t v = expr();
    tp = saved;
    return v;
}

"""#
}
