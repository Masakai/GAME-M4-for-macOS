import Foundation
import GameCore

/// GAME のプログラムを ARM64 の実行ファイルにするコンパイラ。
public enum GameCompiler {
    /// ソースから ARM64 のアセンブリを作る。
    public static func assembly(source: String) throws -> String {
        let reader = try ProgramReader(source: source)
        return CodeGenerator.generate(reader)
    }

    /// ランタイム(C)のソース。Runtime/gm_runtime.c を埋め込んだもの(Tools/embed_runtime.sh)。
    public static func runtimeSource() -> String {
        RuntimeSource.text
    }

    /// ソースをコンパイルして、output に実行ファイルを作る。
    /// アセンブリは `xcrun as` でアセンブルし、ランタイムとともに `xcrun clang` でリンクする。
    public static func build(source: String, output: URL) throws {
        let asm = try assembly(source: source)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamem4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let asmFile = work.appendingPathComponent("program.s")
        let objFile = work.appendingPathComponent("program.o")
        let runtimeFile = work.appendingPathComponent("gm_runtime.c")
        try asm.write(to: asmFile, atomically: true, encoding: .utf8)
        try runtimeSource().write(to: runtimeFile, atomically: true, encoding: .utf8)

        try runTool(["as", "-arch", "arm64", asmFile.path, "-o", objFile.path])
        try runTool(["clang", "-arch", "arm64", "-O2", "-mmacosx-version-min=14.0",
                     objFile.path, runtimeFile.path, "-o", output.path])
    }

    /// xcrun で Xcode の道具を動かす。失敗したら、その出力を誤りとして返す。
    static func runTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: data, as: UTF8.self)
            throw CompileError(line: nil, message: "xcrun \(arguments[0]) が失敗した(終了コード \(process.terminationStatus))\n\(message)")
        }
    }
}
