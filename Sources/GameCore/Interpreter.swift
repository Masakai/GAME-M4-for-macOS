import Foundation

/// GAME 言語のインタプリタ。
///
/// GAME65G(~/Glow65/ROM/game65g/game65g.s)の動きを、ルーチンごとに Swift に移したもの。
/// プログラム、変数、特殊レジスタは 64KB の仮想メモリに GAME65G と同じ番地で置く(設計書 §6)。
/// 本文はメモリ上の文字列を 1 文字ずつ読んで実行する。
public final class Interpreter {
    // ---- 仮想メモリの番地(GAME65G と同じ) ----
    public static let remAddress: UInt16 = 0x08
    public static let pstartAddress: UInt16 = 0x0A
    public static let pendAddress: UInt16 = 0x0C
    public static let ramendAddress: UInt16 = 0x0E
    public static let rndvAddress: UInt16 = 0x10
    public static let varsAddress: UInt16 = 0x80
    public static let lineBuffer: UInt16 = 0x0400
    public static let inputBuffer: UInt16 = 0x0480
    public static let stackAddress: UInt16 = 0x0500
    public static let programAddress: UInt16 = 0x0600
    public static let eofMark: UInt8 = 0xFF
    public static let lockMark: UInt8 = 0xF0
    static let stackMax = 186      // 31 段 × 6 バイト

    public static let banner = "\r\nGAME-M4 V0.1\r\nBASED ON GAME LANGUAGE (ASCII 1978)\r\n"

    /// 実行を止める理由。
    enum Stop: Error {
        case error          // ERR
        case breakKey       // BRK(Ctrl-C)
        case end            // プロンプトへ戻る
        case inputEnded     // 入力が終わった
        case limit          // 実行の上限(テスト用)
    }

    public let console: GameConsole
    /// 仮想メモリ(65536 バイト)。
    public let memory: UnsafeMutablePointer<UInt8>

    // GAME65G のゼロページの作業用の値のうち、プログラムから見えないもの
    private var tp: UInt16 = 0          // 実行・解析中の文字の位置
    private var linep: UInt16 = 0       // 実行中の行の先頭(上位が 0 なら直接実行)
    private var acc: UInt16 = 0         // 式の値
    private var arg: UInt16 = 0         // 二項演算の右辺
    private var ssp = 0                 // 第 2 スタックの使用バイト数
    private var col0 = false            // 行頭にいれば true
    private var ptr1: UInt16 = 0        // 行を探す・表示するときのポインタ
    private var ptr2: UInt16 = 0        // 配列の番地

    /// 中断の確認の残り回数。0 になると止める(テストで無限ループを止めるため)。nil なら制限なし。
    public var stepLimit: Int?

    public init(console: GameConsole) {
        self.console = console
        memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
        memory.initialize(repeating: 0, count: 0x10000)
    }

    deinit {
        memory.deallocate()
    }

    // MARK: - メモリ

    @inline(__always) public func peek(_ a: UInt16) -> UInt8 { memory[Int(a)] }
    @inline(__always) public func poke(_ a: UInt16, _ v: UInt8) { memory[Int(a)] = v }

    @inline(__always) public func peekWord(_ a: UInt16) -> UInt16 {
        UInt16(peek(a)) | UInt16(peek(a &+ 1)) << 8
    }

    @inline(__always) public func pokeWord(_ a: UInt16, _ v: UInt16) {
        poke(a, UInt8(v & 0xFF))
        poke(a &+ 1, UInt8(v >> 8))
    }

    var pstart: UInt16 {
        get { peekWord(Self.pstartAddress) }
        set { pokeWord(Self.pstartAddress, newValue) }
    }
    var pend: UInt16 {
        get { peekWord(Self.pendAddress) }
        set { pokeWord(Self.pendAddress, newValue) }
    }
    var ramend: UInt16 {
        get { peekWord(Self.ramendAddress) }
        set { pokeWord(Self.ramendAddress, newValue) }
    }
    var rndv: UInt16 {
        get { peekWord(Self.rndvAddress) }
        set { pokeWord(Self.rndvAddress, newValue) }
    }
    var rem: UInt16 {
        get { peekWord(Self.remAddress) }
        set { pokeWord(Self.remAddress, newValue) }
    }

    /// 変数 A-Z の値。
    public func variable(_ letter: Character) -> UInt16 {
        let i = UInt16(letter.asciiValue! - 0x41)
        return peekWord(Self.varsAddress + i * 2)
    }

    /// プログラムの行のイメージ(先頭から EOF マークまで)。
    public func programImage() -> [UInt8] {
        let s = pstart
        let e = pend
        guard e >= s else { return [Self.eofMark] }
        return (0...Int(e - s)).map { peek(s &+ UInt16($0)) }
    }

    // MARK: - 起動とプロンプト

    /// コールドスタート。プログラムと変数を消し、バナーを出す。
    public func coldStart(showBanner: Bool = true) {
        pstart = Self.programAddress
        ramend = 0x7FFF
        rndv = 0xACE1                    // 乱数の種(0 以外)
        for i in 0..<52 { poke(Self.varsAddress + UInt16(i), 0) }
        doNew()
        col0 = !showBanner               // バナーなしなら、最初のプロンプトの前に改行しない
        if showBanner { printString(Self.banner) }
        resetForPrompt()
    }

    /// 入力が終わるまで、プロンプトを出して 1 行ずつ実行する。
    public func repl() {
        while true {
            resetForPrompt()
            if !col0 { crlf() }
            out(0x3E)                    // >
            do {
                try getLine(Self.lineBuffer)
                try executeInputLine()
            } catch let stop as Stop {
                switch stop {
                case .error: report("ERR")
                case .breakKey: report("BRK")
                case .end: break
                case .inputEnded, .limit: return
                }
            } catch {
                return
            }
        }
    }

    /// 打ち込んだのと同じく 1 行を処理する(エコーはしない)。ファイルからの読み込みに使う。
    /// 行番号で始まらない行は、prog が true なら false を返して何もしない。false なら直接実行する。
    @discardableResult
    public func enterLine(_ text: [UInt8], programOnly: Bool = false) -> Bool {
        resetForPrompt()
        storeLine(text, at: Self.lineBuffer)
        tp = Self.lineBuffer
        skipsp()
        if programOnly && !isDigit(getc()) {
            return false
        }
        do {
            try executeInputLine()
        } catch let stop as Stop {
            switch stop {
            case .error: report("ERR")
            case .breakKey: report("BRK")
            default: break
            }
        } catch {}
        resetForPrompt()
        return true
    }

    /// 行番号 line から実行する(`#=line` と同じ)。終わるかエラーで止まると戻る。
    public func run(from line: UInt16 = 1) {
        resetForPrompt()
        do {
            acc = line
            try findLine()
            try enterLineAt(ptr1)
            try stmtLoop()
        } catch let stop as Stop {
            switch stop {
            case .error: report("ERR")
            case .breakKey: report("BRK")
            default: break
            }
        } catch {}
        resetForPrompt()
    }

    /// 行頭でなければ改行する(プロンプトの前の処理)。
    public func newLineIfNeeded() {
        if !col0 { crlf() }
    }

    private func resetForPrompt() {
        ssp = 0
        linep &= 0x00FF                  // 上位を 0 にする(直接実行)
    }

    /// エラーか中断の表示。
    private func report(_ message: String) {
        if !col0 { crlf() }
        printString(message)
        if linep >> 8 != 0 {
            out(0x20)
            acc = UInt16(peek(linep)) << 8 | UInt16(peek(linep &+ 1))
            prnum(width: 0)
        }
        crlf()
    }

    /// 入力した行を実行する。行番号で始まれば行の編集、そうでなければ直接実行。
    private func executeInputLine() throws {
        skipsp()
        if isDigit(getc()) {
            try lineCommand()
        } else {
            try stmtLoop()
        }
    }

    // MARK: - 行の編集

    /// 行番号で始まる入力: LIST、行の追加・置き換え・削除。
    private func lineCommand() throws {
        parseNum()
        if getc() == 0x2F || acc == 0 {          // n/ か 0 は LIST
            try list()
            return
        }
        if acc & 0x8000 != 0 { throw Stop.error } // 32767 を超える
        if peek(pend) == Self.lockMark { throw Stop.error }
        findLineNoCheck()
        let p = ptr1
        if peek(p) & 0x80 == 0 && peek(p) == UInt8(acc >> 8) && peek(p &+ 1) == UInt8(acc & 0xFF) {
            deleteLine()                         // 同じ番号の行を消す
        }
        if getc() == 0x0D { return }             // 行番号だけなら削除で終わり
        try insertLine()
    }

    /// ptr1 の行を消す。
    private func deleteLine() {
        let len = UInt16(peek(ptr1 &+ 2))
        var src = ptr1 &+ len
        var dst = ptr1
        var cnt = pend &- src &+ 1
        pend = pend &- len
        while cnt != 0 {
            poke(dst, peek(src))
            src = src &+ 1
            dst = dst &+ 1
            cnt = cnt &- 1
        }
    }

    /// ptr1 の位置に、行番号 acc、本文 tp(CR まで)の行を入れる。
    private func insertLine() throws {
        var y: UInt8 = 0
        while peek(tp &+ UInt16(y)) != 0x0D {
            y = y &+ 1
            if y == 0 { break }
        }
        let len = y &+ 4
        let newEnd = pend &+ UInt16(len)
        if ramend < newEnd { throw Stop.error }
        var src = pend
        var dst = newEnd
        var cnt = pend &- ptr1 &+ 1
        pend = newEnd
        while cnt != 0 {
            poke(dst, peek(src))
            src = src &- 1
            dst = dst &- 1
            cnt = cnt &- 1
        }
        poke(ptr1, UInt8(acc >> 8))
        poke(ptr1 &+ 1, UInt8(acc & 0xFF))
        poke(ptr1 &+ 2, len)
        var i: UInt16 = 0
        while true {
            let c = peek(tp &+ i)
            poke(ptr1 &+ 3 &+ i, c)
            i &+= 1
            if c == 0x0D { break }
        }
    }

    /// 行番号 acc 以上の最初の行を ptr1 に返す(なければ EOF マークの位置)。
    private func findLine() throws {
        findLineNoCheck()
    }

    private func findLineNoCheck() {
        ptr1 = pstart
        while true {
            let hi = peek(ptr1)
            if hi & 0x80 != 0 { return }
            let number = UInt16(hi) << 8 | UInt16(peek(ptr1 &+ 1))
            if number >= acc { return }
            let len = peek(ptr1 &+ 2)
            if len == 0 { return }              // 壊れた行で止める(GAME65G では止まらない)
            ptr1 = ptr1 &+ UInt16(len)
        }
    }

    /// 行番号 acc から最後まで表示する。
    private func list() throws {
        findLineNoCheck()
        while peek(ptr1) & 0x80 == 0 {
            try checkBreak()
            acc = UInt16(peek(ptr1)) << 8 | UInt16(peek(ptr1 &+ 1))
            prnum(width: 0)
            var y: UInt16 = 3
            while true {
                let c = peek(ptr1 &+ y)
                if c == 0x0D { break }
                out(c)
                y &+= 1
                if y == 256 { break }
            }
            crlf()
            let len = peek(ptr1 &+ 2)
            if len == 0 { break }
            ptr1 = ptr1 &+ UInt16(len)
        }
    }

    /// NEW: 末尾を先頭にして EOF マークを書く。
    private func doNew() {
        pend = pstart
        poke(pend, Self.eofMark)
    }

    /// SEARCH END: 先頭から行をたどり、EOF マークの位置を & にする。
    private func searchEnd() {
        var p = pstart
        while true {
            if peek(p) & 0x80 != 0 { break }
            let len = peek(p &+ 2)
            if len == 0 { break }
            p = p &+ UInt16(len)
            if p >> 8 == 0 { break }
        }
        pend = p
    }

    // MARK: - 実行

    private func stmtLoop() throws {
        while true {
            try checkBreak()
            skipsp()
            if getc() == 0x0D {
                try nextLine()
            } else {
                try doStatement()
            }
        }
    }

    /// 次の行へ進む。直接実行ならプロンプトへ戻る。
    private func nextLine() throws {
        if linep >> 8 == 0 { throw Stop.end }
        try enterLineAt(linep &+ UInt16(peek(linep &+ 2)))
    }

    /// p の行から実行を始める。行番号のあとが空白でなければ注釈なので飛ばす。EOF なら終わる。
    private func enterLineAt(_ start: UInt16) throws {
        var p = start
        while true {
            if peek(p) & 0x80 != 0 { throw Stop.end }
            linep = p
            tp = p &+ 3
            if peek(tp) == 0x20 { return }
            if linep >> 8 == 0 { throw Stop.end }
            p = p &+ UInt16(peek(p &+ 2))
        }
    }

    /// 行番号 acc へ飛ぶ(なければそれより大きい最初の行。なければ終了)。
    private func gotoLine() throws {
        findLineNoCheck()
        try enterLineAt(ptr1)
    }

    /// 文を 1 つ実行する。
    private func doStatement() throws {
        let c = getc()
        switch c {
        case 0x22:                      // "
            inctp()
            statementString()
        case 0x2F:                      // /
            inctp()
            crlf()
        case 0x3F:                      // ?
            inctp()
            try statementPrint()
        case 0x24:                      // $
            inctp()
            try eqExpr()
            out(UInt8(acc & 0xFF))
        case 0x2E:                      // .
            inctp()
            try eqExpr()
            var n = acc & 0xFF
            while n > 0 {
                out(0x20)
                n -= 1
            }
        case 0x23:                      // #
            inctp()
            try eqExpr()
            if acc != 0 { try gotoLine() }
        case 0x21:                      // !
            inctp()
            try eqExpr()
            if acc != 0 {
                try pushEntry()
                try gotoLine()
            }
        case 0x5D:                      // ]
            inctp()
            let x = try topEntry()
            ssp = x
            goEntry(x)
        case 0x3E:                      // >(CALL は廃止。設計書 §3)
            throw Stop.error
        case 0x3B:                      // ;
            inctp()
            try eqExpr()
            if acc == 0 {
                while getc() != 0x0D { inctp() }
            }
        case 0x40:                      // @
            inctp()
            try statementDo()
        case 0x3D:                      // =
            inctp()
            try expr()
            pstart = acc
            searchEnd()
        default:
            try assign()
        }
    }

    /// "文字"
    private func statementString() {
        while true {
            let c = getc()
            if c == 0x0D { return }
            inctp()
            if c == 0x22 { return }
            out(c)
        }
    }

    /// ?=n  ?(m)=n  ??=n  ?$=n
    private func statementPrint() throws {
        switch getc() {
        case 0x28:                      // (
            inctp()
            try expr()
            try expectRightParen()
            let width = UInt8(acc & 0xFF)
            try eqExpr()
            prnum(width: width)
        case 0x3F:                      // ?
            inctp()
            try eqExpr()
            printHex2(UInt8(acc >> 8))
            printHex2(UInt8(acc & 0xFF))
        case 0x24:                      // $
            inctp()
            try eqExpr()
            printHex2(UInt8(acc & 0xFF))
        default:
            try eqExpr()
            prnum(width: 0)
        }
    }

    /// @(DO)、@=n(NEXT、UNTIL)
    private func statementDo() throws {
        if getc() != 0x3D {
            acc = 0
            try pushEntry()
            return
        }
        let c = nextc()
        var target: UInt16? = nil
        if isAlpha(c) {
            target = variableAddress(c)  // = の次が変数名なら、値をそこへ入れる
        }
        try expr()
        if let t = target { pokeWord(t, acc) }
        let x = try topEntry()
        let end = Int16(bitPattern: peekWord(Self.stackAddress &+ UInt16(x + 4)))
        if end < Int16(bitPattern: acc) {    // 終値 < 値 ならループを抜ける
            ssp = x
            return
        }
        goEntry(x)
    }

    /// 代入: V=n、V=a,b(FOR)、V(i)=n、V:i)=n。V は A-Z と & * '
    private func assign() throws {
        guard let v = variableAddress(getc()) else { throw Stop.error }
        let c = skipVar()
        if c == 0x28 {                  // (
            inctp()
            try arrayAddress(v, word: true)
            let p = ptr2
            try eqExpr()
            pokeWord(p, acc)
            return
        }
        if c == 0x3A {                  // :
            inctp()
            try arrayAddress(v, word: false)
            let p = ptr2
            try eqExpr()
            poke(p, UInt8(acc & 0xFF))
            return
        }
        try eqExpr()
        pokeWord(v, acc)
        if v == Self.pendAddress && acc == 0 { doNew() }   // &=0 は NEW
        if getc() == 0x2C {             // ,(FOR)
            inctp()
            try expr()
            try pushEntry()
        }
    }

    // MARK: - 第 2 スタック

    /// tp、linep、acc(終値)を積む。
    private func pushEntry() throws {
        if ssp >= Self.stackMax { throw Stop.error }
        let base = Self.stackAddress &+ UInt16(ssp)
        pokeWord(base, tp)
        pokeWord(base &+ 2, linep)
        pokeWord(base &+ 4, acc)
        ssp += 6
    }

    /// 一番上の段の位置を返す(空ならエラー)。
    private func topEntry() throws -> Int {
        if ssp == 0 { throw Stop.error }
        return ssp - 6
    }

    /// x の段の位置へ戻る。
    private func goEntry(_ x: Int) {
        let base = Self.stackAddress &+ UInt16(x)
        tp = peekWord(base)
        linep = peekWord(base &+ 2)
    }

    // MARK: - 式

    /// 優先順位はなく、左から計算する。値は acc。
    private func expr() throws {
        try term()
        while true {
            let op: Operator
            switch getc() {
            case 0x2B: op = .add
            case 0x2D: op = .sub
            case 0x2A: op = .mul
            case 0x2F: op = .div
            case 0x26: op = .and
            case 0x2E: op = .or
            case 0x21: op = .xor
            case 0x3D: op = .eq
            case 0x3C: op = .lt
            case 0x3E: op = .gt
            default: return
            }
            let next = nextc()
            var actual = op
            if op == .lt {
                if next == 0x3E { actual = .ne; inctp() }
                else if next == 0x3D { actual = .le; inctp() }
            } else if op == .gt && next == 0x3D {
                actual = .ge
                inctp()
            }
            let left = acc
            try term()
            arg = acc
            acc = left
            try apply(actual)
        }
    }

    private func apply(_ op: Operator) throws {
        let a = acc, b = arg
        switch op {
        case .add: acc = a &+ b
        case .sub: acc = a &- b
        case .mul: acc = a &* b
        case .div:
            if b == 0 { throw Stop.error }
            let (q, r) = Arithmetic.divide(a, b)
            acc = q
            rem = r
        case .and: acc = a & b
        case .or: acc = a | b
        case .xor: acc = a ^ b
        case .eq: acc = a == b ? 1 : 0
        case .ne: acc = a != b ? 1 : 0
        case .lt: acc = Int16(bitPattern: a) < Int16(bitPattern: b) ? 1 : 0
        case .gt: acc = Int16(bitPattern: a) > Int16(bitPattern: b) ? 1 : 0
        case .le: acc = Int16(bitPattern: a) <= Int16(bitPattern: b) ? 1 : 0
        case .ge: acc = Int16(bitPattern: a) >= Int16(bitPattern: b) ? 1 : 0
        }
    }

    /// 項: (式)、-項、10進数、$16進数、$(1文字入力)、?(数値入力)、%項、'項、変数、配列
    private func term() throws {
        let c = getc()
        switch c {
        case 0x28:                      // (
            inctp()
            try expr()
            try expectRightParen()
        case 0x2D:                      // -
            inctp()
            try term()
            acc = 0 &- acc
        case 0x30...0x39:
            parseNum()
        case 0x24:                      // $
            let n = nextc()
            if isHex(n) {
                parseHex()
            } else {
                try inkey()
            }
        case 0x3F:                      // ?
            inctp()
            try inputNumber()
        case 0x25:                      // %
            inctp()
            try term()
            acc = rem
        case 0x27:                      // '
            inctp()
            try term()
            random()
        default:
            guard let v = variableAddress(c) else { throw Stop.error }
            let n = skipVar()
            if n == 0x28 {
                inctp()
                try arrayAddress(v, word: true)
                acc = peekWord(ptr2)
            } else if n == 0x3A {
                inctp()
                try arrayAddress(v, word: false)
                acc = UInt16(peek(ptr2))
            } else {
                acc = peekWord(v)
            }
        }
    }

    /// 配列の番地: ptr2 = (v の変数の値) + 添字(word なら 2 倍)。tp は ( か : の次。
    private func arrayAddress(_ v: UInt16, word: Bool) throws {
        let base = peekWord(v)              // 基準の番地は添字より先に読む
        try expr()
        try expectRightParen()
        let index = word ? acc &<< 1 : acc
        ptr2 = base &+ index
    }

    /// 10 進数
    private func parseNum() {
        acc = 0
        while true {
            let c = getc()
            guard isDigit(c) else { return }
            acc = acc &* 10 &+ UInt16(c & 0x0F)
            inctp()
        }
    }

    /// 16 進数(tp は最初の桁)
    private func parseHex() {
        acc = 0
        while true {
            let c = getc()
            guard isHex(c) else { return }
            let d = c >= 0x41 ? c - 0x37 : c & 0x0F
            acc = acc &<< 4 | UInt16(d)
            inctp()
        }
    }

    /// 1 文字入力(待たない。なければ 0)
    private func inkey() throws {
        guard let c = console.read(wait: false) else {
            if console.isInputExhausted { throw Stop.inputEnded }
            acc = 0
            return
        }
        if c == 0x03 { throw Stop.breakKey }
        acc = UInt16(c)
    }

    /// 数値入力: 1 行を読み、式として評価する
    private func inputNumber() throws {
        let saved = tp
        try getLine(Self.inputBuffer)
        skipsp()
        try expr()
        tp = saved
    }

    /// 乱数: acc が n なら 1-n(n=0 なら 0)。
    private func random() {
        guard acc != 0 else { return }
        var x = rndv
        let r = Arithmetic.random(n: acc, seed: &x)
        rndv = x
        acc = r
    }

    // MARK: - 文字の読み取り

    @inline(__always) private func inctp() { tp &+= 1 }
    @inline(__always) private func getc() -> UInt8 { peek(tp) }
    @inline(__always) private func nextc() -> UInt8 {
        inctp()
        return getc()
    }

    private func skipsp() {
        while getc() == 0x20 { inctp() }
    }

    /// = を確かめて読み進め、式を評価する
    private func eqExpr() throws {
        if getc() != 0x3D { throw Stop.error }
        inctp()
        try expr()
    }

    private func expectRightParen() throws {
        if getc() != 0x29 { throw Stop.error }
        inctp()
    }

    /// 変数名の文字を読み進める(英字なら続く英字も)。次の文字を返す。
    private func skipVar() -> UInt8 {
        let first = getc()
        var c = nextc()
        if isAlpha(first) {
            while isAlpha(c) { c = nextc() }
        }
        return c
    }

    @inline(__always) private func isAlpha(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
    @inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private func isHex(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46)
    }

    /// 変数の番地を返す(変数でなければ nil)。
    private func variableAddress(_ c: UInt8) -> UInt16? {
        if isAlpha(c) { return Self.varsAddress + UInt16(c - 0x41) * 2 }
        switch c {
        case 0x3D: return Self.pstartAddress   // =
        case 0x26: return Self.pendAddress     // &
        case 0x2A: return Self.ramendAddress   // *
        case 0x27: return Self.rndvAddress     // '
        default: return nil
        }
    }

    // MARK: - 入出力

    /// 1 行を読む。tp をバッファの先頭にする。
    private func getLine(_ buf: UInt16) throws {
        tp = buf
        var y: UInt16 = 0
        while true {
            guard let c = console.read(wait: true) else { throw Stop.inputEnded }
            if c == 0x0D { break }
            if c == 0x03 { throw Stop.breakKey }
            if c == 0x08 || c == 0x7F {
                if y > 0 {
                    y -= 1
                    out(0x08)
                    out(0x20)
                    out(0x08)
                }
                continue
            }
            if c < 0x20 || y >= 120 { continue }
            poke(buf &+ y, c)
            out(c)
            y += 1
        }
        poke(buf &+ y, 0x0D)
        crlf()
        LineText.upcase(memory, at: buf)
    }

    /// エコーせずに 1 行をバッファに入れる(getLine と同じ規則で文字を選ぶ)。
    private func storeLine(_ text: [UInt8], at buf: UInt16) {
        var y: UInt16 = 0
        for c in text {
            if c == 0x0D || c == 0x0A { break }
            if c == 0x08 || c == 0x7F {
                if y > 0 { y -= 1 }
                continue
            }
            if c < 0x20 || y >= 120 { continue }
            poke(buf &+ y, c)
            y += 1
        }
        poke(buf &+ y, 0x0D)
        LineText.upcase(memory, at: buf)
    }

    /// キーが届いていて Ctrl-C なら中断する。
    private func checkBreak() throws {
        if let n = stepLimit {
            if n <= 0 { throw Stop.limit }
            stepLimit = n - 1
        }
        if console.takeBreak() { throw Stop.breakKey }
    }

    @inline(__always) private func out(_ c: UInt8) {
        console.write(c)
        col0 = (c == 0x0A)
    }

    private func crlf() {
        out(0x0D)
        out(0x0A)
    }

    private func printString(_ s: String) {
        for b in s.utf8 { out(b) }
    }

    /// acc を符号付き 10 進で、width 桁の右詰めで表示する。
    private func prnum(width: UInt8) {
        for b in Arithmetic.decimal(acc, width: width) { out(b) }
    }

    private func printHex2(_ v: UInt8) {
        let digits: [UInt8] = Array("0123456789ABCDEF".utf8)
        out(digits[Int(v >> 4)])
        out(digits[Int(v & 0x0F)])
    }

    enum Operator {
        case add, sub, mul, div, and, or, xor, eq, ne, lt, gt, le, ge
    }
}

/// 値の計算のうち、インタプリタとコンパイラ(テスト)で共有するもの。
public enum Arithmetic {
    /// 符号付きの割り算。商は 0 に向けて切り捨て、余りの符号は割られる数に合わせる。b は 0 以外。
    public static func divide(_ a: UInt16, _ b: UInt16) -> (UInt16, UInt16) {
        let x = Int32(Int16(bitPattern: a))
        let y = Int32(Int16(bitPattern: b))
        return (UInt16(truncatingIfNeeded: x / y), UInt16(truncatingIfNeeded: x % y))
    }

    /// xorshift 16 ビット(7、9、8)で種を進め、1 から n(符号なし)の乱数を返す。n は 0 以外。
    public static func random(n: UInt16, seed: inout UInt16) -> UInt16 {
        var x = seed
        if x == 0 { x = 1 }
        x ^= x &<< 7
        x ^= x >> 9
        x ^= x &<< 8
        seed = x
        return x % n &+ 1
    }

    /// 符号付き 10 進の文字列(width 桁の右詰め)。
    public static func decimal(_ value: UInt16, width: UInt8) -> [UInt8] {
        var v = value
        let negative = v & 0x8000 != 0
        if negative { v = 0 &- v }
        var digits: [UInt8] = []
        repeat {
            digits.append(UInt8(v % 10) + 0x30)
            v /= 10
        } while v != 0
        if negative { digits.append(0x2D) }
        var result: [UInt8] = []
        var w = Int(width)
        while w > digits.count {
            result.append(0x20)
            w -= 1
        }
        result.append(contentsOf: digits.reversed())
        return result
    }
}

/// 行の文字列の処理。
public enum LineText {
    /// 文字列と注釈の外の小文字を大文字にする(GAME65G の UPCASE)。行は CR で終わる。
    public static func upcase(_ mem: UnsafeMutablePointer<UInt8>, at buf: UInt16) {
        var y = Int(buf)
        while mem[y] == 0x20 { y += 1 }
        var sawDigit = false
        while mem[y] >= 0x30 && mem[y] <= 0x39 {
            y += 1
            sawDigit = true
        }
        if sawDigit {
            let c = mem[y]
            if c != 0x20 && c != 0x0D && c != 0x2F { return }   // 行番号のあとが空白でない行は注釈
        }
        var quoted = false
        while mem[y] != 0x0D {
            let c = mem[y]
            if c == 0x22 {
                quoted.toggle()
            } else if !quoted && c >= 0x61 && c <= 0x7A {
                mem[y] = c & 0xDF
            }
            y += 1
            if y > 0xFFFF { break }
        }
    }
}
