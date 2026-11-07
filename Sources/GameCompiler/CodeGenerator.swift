import Foundation
import GameCore

/// 構文木から ARM64(Mach-O、Apple Silicon)のアセンブリを作る。
///
/// レジスタの約束(設計書 §8.2):
/// - x19: 仮想メモリの先頭。変数 V は [x19, #番地]
/// - x20: 実行中の行番号(_gm_line)の番地
/// - x21: 中断などの知らせ(_gm_flag)の番地。0 以外なら行の頭で _gm_poll を呼ぶ
/// - w0: 式の値。二項演算の右の値は w1
/// 式の途中の値は 16 バイト単位でスタックに積む(SP は 16 バイト境界のまま)。
struct CodeGenerator {
    private let reader: ProgramReader
    private var out: [String] = []
    private var strings: [[UInt8]] = []
    private var labelCount = 0

    init(reader: ProgramReader) {
        self.reader = reader
    }

    static func generate(_ reader: ProgramReader) -> String {
        var g = CodeGenerator(reader: reader)
        g.emitProgram()
        return g.out.joined(separator: "\n") + "\n"
    }

    // MARK: 全体

    private mutating func emitProgram() {
        out.append("// GAME-M4 コンパイラが生成した ARM64 アセンブリ")
        out.append("    .section __TEXT,__text,regular,pure_instructions")
        out.append("    .globl _main")
        out.append("    .p2align 2")
        out.append("_main:")
        ins("stp x29, x30, [sp, #-48]!")
        ins("mov x29, sp")
        ins("stp x19, x20, [sp, #16]")
        ins("stp x21, x22, [sp, #32]")
        ins("adrp x0, gm_image@PAGE")
        ins("add x0, x0, gm_image@PAGEOFF")
        ins("mov w1, #\(reader.image.count)")
        ins("adrp x2, gm_table@PAGE")
        ins("add x2, x2, gm_table@PAGEOFF")
        ins("mov w3, #\(reader.lines.count)")
        ins("bl _gm_start")
        ins("mov x19, x0")
        ins("adrp x20, _gm_line@GOTPAGE")
        ins("ldr x20, [x20, _gm_line@GOTPAGEOFF]")
        ins("adrp x21, _gm_flag@GOTPAGE")
        ins("ldr x21, [x21, _gm_flag@GOTPAGEOFF]")

        for (i, line) in reader.lines.enumerated() {
            out.append("gm_l\(i):                       // \(line.number)")
            guard let statements = line.statements else { continue }   // 注釈の行は次の行へ進む
            ins("mov w9, #\(line.number)")
            ins("str w9, [x20]")
            ins("ldr w9, [x21]")
            ins("cbz w9, 1f")
            ins("bl _gm_poll")
            out.append("1:")
            let nextLine = i + 1 < reader.lines.count ? "gm_l\(i + 1)" : "gm_end"
            for s in statements {
                emitStatement(s, nextLine: nextLine)
            }
        }
        out.append("gm_end:")
        ins("bl _gm_end")
        ins("brk #1")

        // 文字列
        out.append("    .section __TEXT,__cstring,cstring_literals")
        for (i, s) in strings.enumerated() {
            out.append("gm_s\(i):")
            out.append("    .byte " + (s + [0]).map(String.init).joined(separator: ","))
        }
        // 行のイメージ
        out.append("    .section __TEXT,__const")
        out.append("gm_image:")
        for chunk in stride(from: 0, to: reader.image.count, by: 32) {
            let part = reader.image[chunk..<min(chunk + 32, reader.image.count)]
            out.append("    .byte " + part.map(String.init).joined(separator: ","))
        }
        // 行の表(行番号と、その行のコードの番地)。計算型の #= と != で探す
        out.append("    .section __DATA,__const")
        out.append("    .p2align 3")
        out.append("gm_table:")
        for (i, line) in reader.lines.enumerated() {
            out.append("    .long \(line.number), 0")
            out.append("    .quad gm_l\(i)")
        }
        if reader.lines.isEmpty {
            out.append("    .quad 0")
        }
    }

    // MARK: 文

    private mutating func emitStatement(_ s: Statement, nextLine: String) {
        switch s {
        case .string(let bytes):
            let k = strings.count
            strings.append(bytes)
            ins("adrp x0, gm_s\(k)@PAGE")
            ins("add x0, x0, gm_s\(k)@PAGEOFF")
            ins("bl _gm_str")
        case .newline:
            ins("bl _gm_crlf")
        case .printDecimal(let width, let e):
            if let width {
                emitExpr(width)
                push()
                emitExpr(e)
                ins("ldr x1, [sp], #16")
            } else {
                emitExpr(e)
                ins("mov w1, #0")
            }
            ins("bl _gm_prnum")
        case .printHex4(let e):
            emitExpr(e)
            ins("bl _gm_hex4")
        case .printHex2(let e):
            emitExpr(e)
            ins("bl _gm_hex2")
        case .putChar(let e):
            emitExpr(e)
            ins("bl _gm_putc")
        case .spaces(let e):
            emitExpr(e)
            ins("bl _gm_tab")
        case .goto(let e):
            if let v = e.constant {
                if v != 0 { ins("b \(lineLabel(atLeast: v))") }
            } else {
                emitExpr(e)
                let skip = newLabel()
                ins("tst w0, #0xffff")
                ins("b.eq \(skip)")
                ins("bl _gm_find")
                emitJumpToX0OrEnd()
                out.append("\(skip):")
            }
        case .gosub(let e):
            let resume = newLabel()
            if let v = e.constant {
                if v != 0 {
                    ins("adrp x0, \(resume)@PAGE")
                    ins("add x0, x0, \(resume)@PAGEOFF")
                    ins("mov w1, #\(v)")
                    ins("bl _gm_push")
                    ins("b \(lineLabel(atLeast: v))")
                }
            } else {
                emitExpr(e)
                ins("tst w0, #0xffff")
                ins("b.eq \(resume)")
                ins("mov w1, w0")
                ins("adrp x0, \(resume)@PAGE")
                ins("add x0, x0, \(resume)@PAGEOFF")
                ins("bl _gm_gosub")
                emitJumpToX0OrEnd()
            }
            out.append("\(resume):")
        case .returnFromSub:
            ins("bl _gm_ret")
            ins("br x0")
        case .ifFalseSkipLine(let e):
            emitExpr(e)
            let keep = newLabel()
            ins("tst w0, #0xffff")
            ins("b.ne \(keep)")
            ins("b \(nextLine)")
            out.append("\(keep):")
        case .doLoop:
            let resume = newLabel()
            ins("adrp x0, \(resume)@PAGE")
            ins("add x0, x0, \(resume)@PAGEOFF")
            ins("mov w1, #0")
            ins("bl _gm_push")
            out.append("\(resume):")
        case .next(let target, let e):
            emitExpr(e)
            if let t = target { ins("strh w0, [x19, #\(t)]") }
            let exit = newLabel()
            ins("bl _gm_next")
            ins("cbz x0, \(exit)")
            ins("br x0")
            out.append("\(exit):")
        case .assign(let v, let e):
            emitExpr(e)
            ins("strh w0, [x19, #\(v)]")
        case .forLoop(let v, let first, let last):
            emitExpr(first)
            ins("strh w0, [x19, #\(v)]")
            emitExpr(last)
            let resume = newLabel()
            ins("mov w1, w0")
            ins("adrp x0, \(resume)@PAGE")
            ins("add x0, x0, \(resume)@PAGEOFF")
            ins("bl _gm_push")
            out.append("\(resume):")
        case .assignWord(let v, let index, let e):
            emitArrayAddress(v, index, word: true)
            push()
            emitExpr(e)
            ins("ldr x1, [sp], #16")
            ins("strb w0, [x19, x1]")
            ins("add w2, w1, #1")
            ins("and w2, w2, #0xffff")
            ins("lsr w3, w0, #8")
            ins("strb w3, [x19, x2]")
        case .assignByte(let v, let index, let e):
            emitArrayAddress(v, index, word: false)
            push()
            emitExpr(e)
            ins("ldr x1, [sp], #16")
            ins("strb w0, [x19, x1]")
        }
    }

    /// x0 が 0 なら終了処理へ、そうでなければ x0 の番地へ飛ぶ。
    private mutating func emitJumpToX0OrEnd() {
        let go = newLabel()
        ins("cbnz x0, \(go)")
        ins("b gm_end")
        out.append("\(go):")
        ins("br x0")
    }

    /// 番号が v 以上(符号なしで比べる)の最初の行のラベル。なければ終了処理。
    private func lineLabel(atLeast v: UInt16) -> String {
        if let i = reader.lines.firstIndex(where: { $0.number >= v }) {
            return "gm_l\(i)"
        }
        return "gm_end"
    }

    // MARK: 式

    private mutating func emitExpr(_ e: Expr) {
        switch e {
        case .number(let v):
            ins("mov w0, #\(v)")
        case .variable(let a):
            ins("ldrh w0, [x19, #\(a)]")
        case .wordArray(let v, let index):
            emitArrayAddress(v, index, word: true)
            ins("ldrb w1, [x19, x0]")
            ins("add w2, w0, #1")
            ins("and w2, w2, #0xffff")
            ins("ldrb w2, [x19, x2]")
            ins("orr w0, w1, w2, lsl #8")
        case .byteArray(let v, let index):
            emitArrayAddress(v, index, word: false)
            ins("ldrb w0, [x19, x0]")
        case .negate(let t):
            if let c = e.constant {
                ins("mov w0, #\(c)")
            } else {
                emitExpr(t)
                ins("neg w0, w0")
            }
        case .key:
            ins("bl _gm_key")
        case .input:
            ins("bl _gm_input")
        case .remainder(let t):
            emitExpr(t)
            ins("ldrh w0, [x19, #\(Interpreter.remAddress)]")
        case .random(let t):
            emitExpr(t)
            ins("bl _gm_rnd")
        case .binary(let op, let left, let right):
            emitExpr(left)
            if right.isSimple {
                emitSimple(right, into: "w1")
            } else {
                push()
                emitExpr(right)
                ins("mov w1, w0")
                ins("ldr x0, [sp], #16")
            }
            emitOperator(op)
        }
    }

    private mutating func emitSimple(_ e: Expr, into reg: String) {
        switch e {
        case .number(let v): ins("mov \(reg), #\(v)")
        case .variable(let a): ins("ldrh \(reg), [x19, #\(a)]")
        default: fatalError("単純な項ではない")
        }
    }

    private mutating func emitOperator(_ op: BinaryOperator) {
        switch op {
        case .add: ins("add w0, w0, w1")
        case .sub: ins("sub w0, w0, w1")
        case .mul: ins("mul w0, w0, w1")
        case .div: ins("bl _gm_div")
        case .and: ins("and w0, w0, w1")
        case .or: ins("orr w0, w0, w1")
        case .xor: ins("eor w0, w0, w1")
        case .eq, .ne:
            ins("and w0, w0, #0xffff")
            ins("and w1, w1, #0xffff")
            ins("cmp w0, w1")
            ins("cset w0, \(op == .eq ? "eq" : "ne")")
        case .lt, .gt, .le, .ge:
            ins("sxth w0, w0")
            ins("sxth w1, w1")
            ins("cmp w0, w1")
            let cond: String
            switch op {
            case .lt: cond = "lt"
            case .gt: cond = "gt"
            case .le: cond = "le"
            default: cond = "ge"
            }
            ins("cset w0, \(cond)")
        }
    }

    /// 配列の要素の番地を w0 に作る(16 ビットで回る)。基準の番地は添字より先に読む。
    private mutating func emitArrayAddress(_ v: UInt16, _ index: Expr, word: Bool) {
        ins("ldrh w0, [x19, #\(v)]")
        if index.isSimple {
            emitSimple(index, into: "w1")
        } else {
            push()
            emitExpr(index)
            ins("mov w1, w0")
            ins("ldr x0, [sp], #16")
        }
        ins(word ? "add w0, w0, w1, lsl #1" : "add w0, w0, w1")
        ins("and w0, w0, #0xffff")
    }

    // MARK: 補助

    private mutating func push() {
        ins("str x0, [sp, #-16]!")
    }

    private mutating func newLabel() -> String {
        labelCount += 1
        return "gm_r\(labelCount)"
    }

    private mutating func ins(_ s: String) {
        out.append("    " + s)
    }
}
