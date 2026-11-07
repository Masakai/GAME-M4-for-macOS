import Darwin
import Foundation
import GameCompiler
import GameCore

// 使い方:
//   gamem4                              対話モード
//   gamem4 prog.gam                     読み込んで #=1 で実行する
//   gamem4 -i prog.gam                  読み込んで対話モードに入る
//   gamem4 compile prog.gam -o prog     実行ファイルを作る
//   gamem4 compile prog.gam -S -o prog.s  アセンブリだけを出す
// 端末では Ctrl-C で実行を止め、Ctrl-\ か Ctrl-D で終わる。

let usage = """
使い方: gamem4 [-i] [プログラム.gam]
        gamem4 compile プログラム.gam [-S] [-o 出力]
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

func readSource(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("ファイルを読めない: \(path)", code: 1)
    }
    return String(decoding: data, as: UTF8.self)
}

/// プログラムの行を、打ち込んだのと同じく 1 行ずつ入れる(エコーしない)。
func load(_ source: String, into interp: Interpreter) {
    for line in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
        let bytes = Array(line.utf8)
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
        interp.enterLine(bytes)
    }
}

func compileCommand(_ args: [String]) -> Never {
    var input: String?
    var output: String?
    var assemblyOnly = false
    var rest = args[...]
    while let a = rest.popFirst() {
        switch a {
        case "-o":
            guard let o = rest.popFirst() else { fail(usage) }
            output = o
        case "-S":
            assemblyOnly = true
        default:
            if a.hasPrefix("-") || input != nil { fail(usage) }
            input = a
        }
    }
    guard let input else { fail(usage) }
    let source = readSource(input)
    let base = URL(fileURLWithPath: input).deletingPathExtension()
    do {
        if assemblyOnly {
            let asm = try GameCompiler.assembly(source: source)
            let path = output ?? base.appendingPathExtension("s").path
            try asm.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            let path = output ?? base.path
            try GameCompiler.build(source: source, output: URL(fileURLWithPath: path))
        }
    } catch let e as CompileError {
        fail("\(input): \(e)", code: 1)
    } catch {
        fail("\(input): \(error)", code: 1)
    }
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "compile" {
    compileCommand(Array(arguments.dropFirst()))
}

var interactive = false
var programPath: String?
for a in arguments {
    switch a {
    case "-i": interactive = true
    case "-h", "--help": fail(usage, code: 0)
    default:
        if a.hasPrefix("-") || programPath != nil { fail(usage) }
        programPath = a
    }
}

let console = StdioConsole()
let interp = Interpreter(console: console)
if let programPath {
    let source = readSource(programPath)
    interp.coldStart(showBanner: interactive)
    load(source, into: interp)
    if !interactive {
        interp.run(from: 1)
        interp.newLineIfNeeded()
        console.restore()
        exit(0)
    }
} else {
    interp.coldStart()
}
interp.repl()
console.restore()
