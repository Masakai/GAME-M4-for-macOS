import Foundation
import GameCore

/// コンパイル時の誤り。
public struct CompileError: Error, CustomStringConvertible {
    /// GAME の行番号(行に属さない誤りなら nil)。
    public let line: Int?
    public let message: String
    /// 誤りのあった行の本文と、文字の位置(0 から)。
    public let text: String?
    public let column: Int?

    public init(line: Int?, message: String, text: String? = nil, column: Int? = nil) {
        self.line = line
        self.message = message
        self.text = text
        self.column = column
    }

    public var description: String {
        var s = line.map { "\($0) 行: \(message)" } ?? message
        if let text {
            s += "\n    \(text)"
            if let column {
                s += "\n    " + String(repeating: " ", count: column) + "^"
            }
        }
        return s
    }
}

/// 式。値はすべて 16 ビット。
indirect enum Expr {
    case number(UInt16)
    case variable(UInt16)                // 変数の番地(A-Z と = & * ')
    case wordArray(UInt16, Expr)         // V(i)
    case byteArray(UInt16, Expr)         // V:i)
    case negate(Expr)
    case key                             // $(1 文字入力。待たない)
    case input                           // ?(1 行を読んで式として評価)
    case remainder(Expr)                 // %t
    case random(Expr)                    // 't
    case binary(BinaryOperator, Expr, Expr)

    /// 定数なら値。
    var constant: UInt16? {
        switch self {
        case .number(let v): return v
        case .negate(let e): return e.constant.map { 0 &- $0 }
        default: return nil
        }
    }

    /// 副作用がなく、レジスタに直接読める項(定数か変数)。
    var isSimple: Bool {
        switch self {
        case .number, .variable: return true
        default: return false
        }
    }
}

enum BinaryOperator {
    case add, sub, mul, div, and, or, xor, eq, ne, lt, gt, le, ge
}

/// 文。
enum Statement {
    case string([UInt8])                 // "文字"
    case newline                         // /
    case printDecimal(width: Expr?, Expr) // ?=e、?(m)=e
    case printHex4(Expr)                 // ??=e
    case printHex2(Expr)                 // ?$=e
    case putChar(Expr)                   // $=e
    case spaces(Expr)                    // .=e
    case goto(Expr)                      // #=e
    case gosub(Expr)                     // !=e
    case returnFromSub                   // ]
    case ifFalseSkipLine(Expr)           // ;=e
    case doLoop                          // @
    case next(UInt16?, Expr)             // @=e(= の次が変数名なら、その変数に入れる)
    case assign(UInt16, Expr)            // V=e
    case forLoop(UInt16, Expr, Expr)     // V=a,b
    case assignWord(UInt16, Expr, Expr)  // V(i)=e
    case assignByte(UInt16, Expr, Expr)  // V:i)=e
}

/// プログラムの 1 行。
struct ProgramLine {
    let number: UInt16
    /// 注釈の行(行番号の後ろが空白でない行)なら nil。
    let statements: [Statement]?
}

/// 1 行の本文を、インタプリタ(GAME65G の STMT、TERM、EXPR)と同じ 1 文字ずつの規則で読む。
struct LineParser {
    private let text: [UInt8]           // 本文(CR で終わる)
    private var tp = 0
    private let lineNumber: UInt16

    init(text: [UInt8], lineNumber: UInt16) {
        self.text = text.last == 0x0D ? text : text + [0x0D]
        self.lineNumber = lineNumber
    }

    mutating func parseStatements() throws -> [Statement] {
        var result: [Statement] = []
        while true {
            skipsp()
            if getc() == 0x0D { return result }
            result.append(try statement())
        }
    }

    private func fail(_ message: String) -> CompileError {
        let body = String(decoding: text.dropLast(), as: UTF8.self)
        let prefix = String(lineNumber)
        return CompileError(line: Int(lineNumber), message: message,
                            text: prefix + body, column: prefix.count + min(tp, text.count - 1))
    }

    private mutating func statement() throws -> Statement {
        let c = getc()
        switch c {
        case 0x22:                      // "
            inctp()
            var bytes: [UInt8] = []
            while true {
                let d = getc()
                if d == 0x0D { break }
                inctp()
                if d == 0x22 { break }
                bytes.append(d)
            }
            return .string(bytes)
        case 0x2F:                      // /
            inctp()
            return .newline
        case 0x3F:                      // ?
            inctp()
            switch getc() {
            case 0x28:
                inctp()
                let width = try expr()
                try expectRightParen()
                return .printDecimal(width: width, try eqExpr())
            case 0x3F:
                inctp()
                return .printHex4(try eqExpr())
            case 0x24:
                inctp()
                return .printHex2(try eqExpr())
            default:
                return .printDecimal(width: nil, try eqExpr())
            }
        case 0x24:                      // $
            inctp()
            return .putChar(try eqExpr())
        case 0x2E:                      // .
            inctp()
            return .spaces(try eqExpr())
        case 0x23:                      // #
            inctp()
            return .goto(try eqExpr())
        case 0x21:                      // !
            inctp()
            return .gosub(try eqExpr())
        case 0x5D:                      // ]
            inctp()
            return .returnFromSub
        case 0x3E:                      // >
            throw fail("CALL(>=)は使えない")
        case 0x3B:                      // ;
            inctp()
            return .ifFalseSkipLine(try eqExpr())
        case 0x40:                      // @
            inctp()
            if getc() != 0x3D { return .doLoop }
            let d = nextc()
            let target: UInt16? = isAlpha(d) ? variableAddress(d) : nil
            return .next(target, try expr())
        case 0x3D:                      // =
            throw fail("プログラムの先頭の変更(=式、==)はコンパイルできない")
        default:
            return try assign()
        }
    }

    private mutating func assign() throws -> Statement {
        guard let v = variableAddress(getc()) else { throw fail("文の始まりが正しくない") }
        let c = skipVar()
        if c == 0x28 {
            inctp()
            let index = try expr()
            try expectRightParen()
            return .assignWord(v, index, try eqExpr())
        }
        if c == 0x3A {
            inctp()
            let index = try expr()
            try expectRightParen()
            return .assignByte(v, index, try eqExpr())
        }
        if v == Interpreter.pendAddress {
            throw fail("プログラムの末尾の変更(&=式)はコンパイルできない")
        }
        let value = try eqExpr()
        if getc() == 0x2C {
            inctp()
            return .forLoop(v, value, try expr())
        }
        return .assign(v, value)
    }

    // MARK: 式

    private mutating func expr() throws -> Expr {
        var left = try term()
        while true {
            let op: BinaryOperator
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
            default: return left
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
            left = .binary(actual, left, try term())
        }
    }

    private mutating func term() throws -> Expr {
        let c = getc()
        switch c {
        case 0x28:
            inctp()
            let e = try expr()
            try expectRightParen()
            return e
        case 0x2D:
            inctp()
            return .negate(try term())
        case 0x30...0x39:
            var v: UInt16 = 0
            while isDigit(getc()) {
                v = v &* 10 &+ UInt16(getc() & 0x0F)
                inctp()
            }
            return .number(v)
        case 0x24:
            let n = nextc()
            if !isHex(n) { return .key }
            var v: UInt16 = 0
            while isHex(getc()) {
                let d = getc()
                v = v &<< 4 | UInt16(d >= 0x41 ? d - 0x37 : d & 0x0F)
                inctp()
            }
            return .number(v)
        case 0x3F:
            inctp()
            return .input
        case 0x25:
            inctp()
            return .remainder(try term())
        case 0x27:
            inctp()
            return .random(try term())
        default:
            guard let v = variableAddress(c) else { throw fail("式が正しくない") }
            let n = skipVar()
            if n == 0x28 {
                inctp()
                let index = try expr()
                try expectRightParen()
                return .wordArray(v, index)
            }
            if n == 0x3A {
                inctp()
                let index = try expr()
                try expectRightParen()
                return .byteArray(v, index)
            }
            return .variable(v)
        }
    }

    // MARK: 文字の読み取り

    private mutating func inctp() {
        if tp < text.count - 1 { tp += 1 }     // CR の先へは進まない
    }

    private func getc() -> UInt8 { text[tp] }

    private mutating func nextc() -> UInt8 {
        inctp()
        return getc()
    }

    private mutating func skipsp() {
        while getc() == 0x20 { inctp() }
    }

    private mutating func eqExpr() throws -> Expr {
        if getc() != 0x3D { throw fail("= がない") }
        inctp()
        return try expr()
    }

    private mutating func expectRightParen() throws {
        if getc() != 0x29 { throw fail(") がない") }
        inctp()
    }

    private mutating func skipVar() -> UInt8 {
        let first = getc()
        var c = nextc()
        if isAlpha(first) {
            while isAlpha(c) { c = nextc() }
        }
        return c
    }

    private func isAlpha(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) }

    private func variableAddress(_ c: UInt8) -> UInt16? {
        if isAlpha(c) { return Interpreter.varsAddress + UInt16(c - 0x41) * 2 }
        switch c {
        case 0x3D: return Interpreter.pstartAddress
        case 0x26: return Interpreter.pendAddress
        case 0x2A: return Interpreter.ramendAddress
        case 0x27: return Interpreter.rndvAddress
        default: return nil
        }
    }
}

/// GAME のソースを読み、行のイメージと構文木を作る。
struct ProgramReader {
    /// 行のイメージ($0600 に置くバイト列。EOF マークまで)。
    let image: [UInt8]
    let lines: [ProgramLine]

    init(source: String) throws {
        let console = BufferConsole()
        let interp = Interpreter(console: console)
        interp.coldStart(showBanner: false)
        // 行は端末に打ち込んだのと同じく、インタプリタの行エディタで入れる(同じ番号の行は置き換わる)
        var sourceLine = 0
        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            sourceLine += 1
            let bytes = Array(raw.utf8)
            if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            console.clearOutput()
            let isProgramLine = interp.enterLine(bytes, programOnly: true)
            if !isProgramLine {
                throw CompileError(line: nil,
                                   message: "ソースの \(sourceLine) 行目に行番号がない(コンパイルできるのはプログラムの行だけ)",
                                   text: String(raw))
            }
            if console.text.contains("ERR") {
                throw CompileError(line: nil, message: "ソースの \(sourceLine) 行目を入れられない(行番号が 32767 を超えるか、メモリが足りない)",
                                   text: String(raw))
            }
        }
        image = interp.programImage()

        var parsed: [ProgramLine] = []
        var p = 0
        while p < image.count && image[p] & 0x80 == 0 {
            let number = UInt16(image[p]) << 8 | UInt16(image[p + 1])
            let length = Int(image[p + 2])
            let body = Array(image[(p + 3)..<(p + length)])
            if body.first == 0x20 {
                var parser = LineParser(text: body, lineNumber: number)
                parsed.append(ProgramLine(number: number, statements: try parser.parseStatements()))
            } else {
                parsed.append(ProgramLine(number: number, statements: nil))
            }
            p += length
        }
        lines = parsed
    }
}
