import XCTest
@testable import GameCompiler
@testable import GameCore

/// コンパイラのテスト。同じプログラムをインタプリタで動かした出力と、
/// コンパイルした実行ファイルを動かした出力が、バイト単位で一致することを確かめる(設計書 §10)。
final class CompilerTests: XCTestCase {
    private static var work: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamem4-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var serial = 0

    /// インタプリタで、ファイルを読み込んで #=1 で実行したときの出力(CLI の gamem4 prog.gam と同じ手順)。
    private func interpret(_ source: String, input: String) -> String {
        let console = BufferConsole(input: input.replacingOccurrences(of: "\n", with: "\r"))
        console.input.close()
        let interp = Interpreter(console: console)
        interp.coldStart(showBanner: false)
        interp.stepLimit = 50_000_000
        for line in source.split(separator: "\n") {
            interp.enterLine(Array(line.utf8))
        }
        interp.run(from: 1)
        interp.newLineIfNeeded()
        return String(decoding: console.output, as: UTF8.self)
    }

    /// コンパイルして動かしたときの出力と終了コード。入力はファイルから流す。
    private func compileAndRun(_ source: String, input: String) throws -> (String, Int32) {
        serial += 1
        let exe = Self.work.appendingPathComponent("prog\(serial)-\(name.filter { $0.isLetter })")
        try GameCompiler.build(source: source, output: exe)
        let inputFile = exe.appendingPathExtension("in")
        try Data(input.utf8).write(to: inputFile)
        let process = Process()
        process.executableURL = exe
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // 止まらないときは 30 秒で打ち切る
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// 両方で動かして出力を比べ、コンパイル版の出力(CR を除く)と終了コードを返す。
    @discardableResult
    private func same(_ lines: [String], input: String = "", status: Int32 = 0,
                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let source = lines.joined(separator: "\n")
        let expected = interpret(source, input: input)
        let (actual, code) = try compileAndRun(source, input: input)
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(code, status, "終了コード", file: file, line: line)
        return actual.replacingOccurrences(of: "\r", with: "")
    }

    private func compileError(_ lines: [String]) -> CompileError? {
        do {
            _ = try GameCompiler.assembly(source: lines.joined(separator: "\n"))
            return nil
        } catch let e as CompileError {
            return e
        } catch {
            return nil
        }
    }

    // MARK: 出力と式

    func testPrintFormats() throws {
        let text = try same(["10 ?=1234 ?=-5 ?(6)=42 ?(2)=1234 / ??=$1841 ?$=$1841 $=65 .=3 \"AB\"/\"CD\"//"])
        XCTAssertEqual(text, "1234-5    421234\n184141A   AB\nCD\n\n")
    }

    func testExpressions() throws {
        try same([
            "10 ?=-32768 / ?=32767+1 / ?=$FFFF / ?=2+3*4 / ?=2+(3*4)",
            "20 ?=17/5 / ?=%1 / ?=-17/5 / ?=%(-17/5) / ?=17/-5 / ?=7/2 ?=%(9/4)",
            "30 ?=(1<2) ?=(2<1) ?=(-1<1) ?=(3=3) ?=(3<>3) ?=(2<=2) ?=(3>=4) ?=(5>4) ?=(-3>=-3)",
            "40 ??=$F0F0&$0FF0 / ??=$F000.$000F / ??=$FFFF!$8080 / ?=$A+1",
            "50 alpha=7 ?=A+ab / A=300 B=-7 ?=A*B ?=A/B ?=%0 ?=-A ?=(A=300)*(B<0)",
            "60 X=1000 Y=X*X ?=Y / ?=(X+X)*(X-1)/3",
        ])
    }

    func testDivideByZeroIsAnError() throws {
        let text = try same(["10 ?=1", "20 ?=1/0", "30 ?=3"], status: 1)
        XCTAssertEqual(text, "1\nERR 20\n")
    }

    // MARK: 配列とメモリ

    func testArraysAndSpecialRegisters() throws {
        try same([
            "10 A=$3000 A(0)=$1234 A(1)=-2 ?$=A:0) ?$=A:1) ?=A(1) B=$3010 B:2)=65 $=B:2) /",
            "20 ??== ??=& ??=* / C=&+1 C(0)=-7 ?=C(0) ??=C /",
            "30 Z=$80 B=$4321 ??=Z(1) / I=0,3 A(I+2)=I*I @=I+1 I=0,3 ?=A(I+2) .=1 @=I+1 /",
            "40 P=$FFFF P:0)=9 ?=P:0) ?=Z:0) /",
        ])
    }

    // MARK: 制御

    func testLoops() throws {
        try same([
            "10 I=1,5 ?=I @=I+1",
            "20 / I=-2,2 ?=I .=1 @=I+1",
            "30 / K=0 @ K=K+3 @=(K>10) ?=K",
            "40 / I=1,3 J=1,2 ?=I*10+J .=1 @=J+1 @=I+1",
            "50 / K=0 I=1,32767 K=K+1 ;=K<3 @=-1",
            "60 ?=K / I=10,1 ?=I @=I-1",
        ])
    }

    func testGotoGosubIfAndEnd() throws {
        let text = try same([
            "10 N=0",
            "20 !=100",
            "30 ;=N<3 #=20",
            "40 \"DONE\" / T=200 !=T*1 X=3 #=X*100",
            "50 \"NOT REACHED\"",
            "100 N=N+1 ?=N ]",
            "200 \"SUB\" ]",
            "250REM COMMENT",
            "260 \"END\" #=-1",
            "300 \"THREE\" / #=250",
        ])
        XCTAssertEqual(text, "123DONE\nSUBTHREE\nEND\n")
    }

    func testGotoTargets() throws {
        try same(["10 ?=1 #=20", "15 ?=15", "25REM", "30 ?=3 #=-5", "40 ?=4"])
        try same(["10 ?=1 #=99", "20 ?=2"])
        try same(["10 N=25 #=N", "20 ?=2", "30 ?=3 N=0 #=N ?=4"])
    }

    func testReturnPopsLoopEntryAndStackErrors() throws {
        XCTAssertEqual(try same(["10 I=1,3 ?=I ]"], status: 1), "11\nERR 10\n")
        XCTAssertEqual(try same(["10 !=10"], status: 1), "ERR 10\n")
        XCTAssertEqual(try same(["10 ?=1 / @=1"], status: 1), "1\nERR 10\n")
    }

    func testErrorLineAfterReturnIsCallersLine() throws {
        // ] で戻ると、エラーの行番号も呼んだ行に戻る
        try same(["10 !=100 ?=1/0", "100 ]"], status: 1)
    }

    // MARK: 乱数と入力

    func testRandom() throws {
        try same(["10 I=1,20 ?='100 .=1 @=I+1", "20 / '=1234 I=1,10 ?='6 @=I+1 / ?='0 ?='-1"])
    }

    func testNumericInput() throws {
        let text = try same([
            "10 \"N? \" A=? ?=A*2 /",
            "20 \"M? \" B=? ?=B /",
        ], input: "3+4\nA*10\n")
        XCTAssertEqual(text, "N? 3+4\n14\nM? A*10\n70\n")
    }

    func testNumericInputEditsAndUppercase() throws {
        try same(["10 A=? B=? ?=A+B"], input: "12\u{8}3\nzz+1\n")
    }

    func testInputErrorShowsLine() throws {
        try same(["10 A=?", "20 ?=A"], input: ")\n", status: 1)
    }

    func testCharacterInput() throws {
        try same(["10 @ K=$ @=(K<>0) ?=K", "20 A=$ ?=A"], input: "x")
    }

    /// 入力が終わったら、$ の空回りはせずに終える。
    func testCharacterInputAtEndOfInput() throws {
        try same(["10 \"WAIT\" @ K=$ @=(K<>0)", "20 \"NOT REACHED\""])
    }

    func testCtrlCBreaks() throws {
        let text = try same(["10 #=10"], input: "\u{03}", status: 130)
        XCTAssertEqual(text, "BRK 10\n")
    }

    // MARK: ドキュメントの例

    func testMultiplicationTable() throws {
        try same(["10 I=1,9", "20 J=1,9 ?(3)=I*J @=J+1", "30 / @=I+1"])
    }

    func testGuessingGame() throws {
        // 答えは、キーを読むまでに回した乱数で決まる。入力の数はでたらめでよい(両者で同じに動けばよい)
        try same([
            "10 \"PRESS A KEY\" / @ N='100 K=$ @=(K<>0)",
            "20 C=0",
            "30 \"1-100? \" G=? C=C+1",
            "40 ;=G<N \"UP\" / #=30",
            "50 ;=G>N \"DOWN\" / #=30",
            "60 \"OK \" ?=C / #=-1",
        ], input: " 50\n25\n75\n12\n37\n62\n87\n6\n18\n31\n43\n56\n68\n81\n93\n")
    }

    /// アプリの最初のサンプル(examples/mandel.gam)。テストでは反復の上限を下げる。
    func testMandelbrotSample() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../examples/mandel.gam").standardized
        let source = try String(contentsOf: path, encoding: .utf8)
        let lines = source.split(separator: "\n").map { $0.hasPrefix("40 M=") ? "40 M=300" : String($0) }
        let text = try same(lines)
        XCTAssertEqual(text.split(separator: "\n").count, 25, text)
        XCTAssertTrue(text.contains("####"), text)
    }

    func testStarTrek() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Programs/startrek.gam")
        let source = try String(contentsOf: path, encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)
        let commands = [" ", "0", "1", "2", "3", "1", "4", "5", "45", "100", "6", "7", "8", "9", "11", "1",
                        "2", "1", "3", "1", "5", "300", "1", "4", "5", "0", "4", "1", "1", "8", "8", "6"]
        let text = try same(lines, input: commands.joined(separator: "\n") + "\n")
        XCTAssertTrue(text.contains("*** STAR TREK ***"), text)
    }

    // MARK: コンパイル時の誤り

    func testCompileErrors() {
        XCTAssertEqual(compileError(["10 =$3000"])?.line, 10)
        XCTAssertEqual(compileError(["10 ?=1", "20 =="])?.line, 20)
        XCTAssertEqual(compileError(["10 &=0"])?.line, 10)
        XCTAssertEqual(compileError(["10 >=$300"])?.line, 10)
        XCTAssertEqual(compileError(["10 ?=1", "20 ?=)"])?.line, 20)
        XCTAssertEqual(compileError(["10 ?=A/"])?.line, 10)
        XCTAssertEqual(compileError(["10 ?=1", "?=2"])?.line, nil)
        XCTAssertNotNil(compileError(["10 ?=1", "?=2"]))
        XCTAssertNil(compileError(["10 &:0)=$F0 *=$7000 '=5"]))
    }

    /// 埋め込んだランタイムが、Runtime/gm_runtime.c と同じ(Tools/embed_runtime.sh の実行忘れを見つける)。
    func testEmbeddedRuntimeMatchesFile() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/GameCompiler/Runtime/gm_runtime.c").standardized
        let file = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(GameCompiler.runtimeSource(), file)
    }

    /// 同じ番号の行は、インタプリタと同じく後の行で置き換わり、番号の順に並ぶ。
    func testLineReplacementAndOrder() throws {
        let text = try same(["20 ?=2", "10 ?=1", "20 ?=22", "30 ?=3", "30"])
        XCTAssertEqual(text, "122\n")
    }
}
