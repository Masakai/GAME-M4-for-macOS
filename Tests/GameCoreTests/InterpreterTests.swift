import XCTest
@testable import GameCore

/// インタプリタのテスト。多くは ~/Glow65/Tests/Glow65Tests/Game65GTests.swift を移したもの。
/// 期待する出力は、本物の 6502 で動く GAME65G の出力と同じ(バナーの版と、廃止した命令を除く)。
final class InterpreterTests: XCTestCase {
    /// 行を 1 行ずつ打ち込み、最後の行を打ち込んだあとの出力を返す(CR は除く)。
    /// later は、最後の行のあと、実行中に打つキー(中断の確認を 100 回したあとで届く)。
    private func run(_ lines: [String], later: String? = nil, steps: Int = 2_000_000) -> String {
        let console = BufferConsole()
        let interp = Interpreter(console: console)
        interp.coldStart(showBanner: false)
        interp.stepLimit = steps
        var rest = lines[...]
        console.onNeedInput = { c in
            guard let line = rest.popFirst() else { return false }
            if rest.isEmpty {
                c.clearOutput()
                if let later { c.sendLater(later, afterPolls: 100) }
            }
            c.send(line + "\r")
            return true
        }
        interp.repl()
        return console.text
    }

    private func expect(_ lines: [String], later: String? = nil, _ expected: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run(lines, later: later), expected, file: file, line: line)
    }

    /// 対話の相手を自由に書けるようにした実行。handler が false を返すと入力の終わり。
    private func session(_ handler: @escaping (BufferConsole) -> Bool) -> BufferConsole {
        let console = BufferConsole()
        let interp = Interpreter(console: console)
        interp.coldStart(showBanner: false)
        interp.stepLimit = 2_000_000
        console.onNeedInput = handler
        interp.repl()
        return console
    }

    func testBannerAndPrompt() {
        let console = BufferConsole()
        let interp = Interpreter(console: console)
        interp.coldStart()
        interp.repl()
        XCTAssertEqual(console.text, "\nGAME-M4 V0.1\nBASED ON GAME LANGUAGE (ASCII 1978)\n>")
    }

    // MARK: 出力

    func testPrintDecimalLeftAndRight() {
        expect(["?=1234 ?=-5 ?(6)=42 ?(2)=1234"], "?=1234 ?=-5 ?(6)=42 ?(2)=1234\n1234-5    421234\n>")
    }

    func testPrintHexCharSpacesStringsAndNewline() {
        expect(["??=$1841 ?$=$1841 $=65 .=3 \"AB\"/\"CD\"//"],
               "??=$1841 ?$=$1841 $=65 .=3 \"AB\"/\"CD\"//\n184141A   AB\nCD\n\n>")
    }

    func testExtremeValues() {
        expect(["?=-32768 / ?=32767+1 / ?=$FFFF"], "?=-32768 / ?=32767+1 / ?=$FFFF\n-32768\n-32768\n-1\n>")
    }

    // MARK: 式

    func testLeftToRightWithoutPrecedence() {
        expect(["?=2+3*4 / ?=2+(3*4)"], "?=2+3*4 / ?=2+(3*4)\n20\n14\n>")
    }

    func testDivisionAndRemainder() {
        expect(["?=17/5 / ?=%1 / ?=-17/5 / ?=%(-17/5) / ?=17/-5"],
               "?=17/5 / ?=%1 / ?=-17/5 / ?=%(-17/5) / ?=17/-5\n3\n2\n-3\n-2\n-3\n>")
    }

    func testComparisonsAreSigned() {
        expect(["?=(1<2) ?=(2<1) ?=(-1<1) ?=(3=3) ?=(3<>3) ?=(2<=2) ?=(3>=4) ?=(5>4)"],
               "?=(1<2) ?=(2<1) ?=(-1<1) ?=(3=3) ?=(3<>3) ?=(2<=2) ?=(3>=4) ?=(5>4)\n10110101\n>")
    }

    func testBitwiseOperators() {
        expect(["??=$F0F0&$0FF0 / ??=$F000.$000F / ??=$FFFF!$8080"],
               "??=$F0F0&$0FF0 / ??=$F000.$000F / ??=$FFFF!$8080\n00F0\nF00F\n7F7F\n>")
    }

    func testVariablesIgnoreLaterLettersAndLowercase() {
        expect(["alpha=7 ?=A+ab"], "alpha=7 ?=A+ab\n14\n>")
    }

    func testDivideByZeroIsAnError() {
        expect(["?=1/0"], "?=1/0\nERR\n>")
    }

    // MARK: 配列とメモリ

    func testArrays() {
        expect(["A=$3000 A(0)=$1234 A(1)=-2 ?$=A:0) ?$=A:1) ?=A(1) B=$3010 B:2)=65 $=B:2)"],
               "A=$3000 A(0)=$1234 A(1)=-2 ?$=A:0) ?$=A:1) ?=A(1) B=$3010 B:2)=65 $=B:2)\n3412-2A\n>")
    }

    func testArrayAfterProgramEnd() {
        expect(["10 ?=1", "A=&+1 A(0)=-7 ?=A(0) ??=A"], "A=&+1 A(0)=-7 ?=A(0) ??=A\n-70609\n>")
    }

    /// 変数は仮想メモリの $80 から置く(GAME65G と同じ)。
    func testVariablesLiveInMemory() {
        expect(["B=$1234 Z=$80 ??=Z(1)"], "B=$1234 Z=$80 ??=Z(1)\n1234\n>")
    }

    // MARK: プログラム

    func testEnterListRunAndDelete() {
        expect(["20 ?=2", "10 ?=1", "30 ?=3", "20 ?=22", "0"], "0\n10 ?=1\n20 ?=22\n30 ?=3\n>")
        expect(["20 ?=2", "10 ?=1", "30 ?=3", "20 ?=22", "20/"], "20/\n20 ?=22\n30 ?=3\n>")
        expect(["20 ?=2", "10 ?=1", "30 ?=3", "20 ?=22", "#=1"], "#=1\n1223\n>")
        expect(["20 ?=2", "10 ?=1", "30 ?=3", "20", "0"], "0\n10 ?=1\n30 ?=3\n>")
    }

    func testCommentLineIsSkippedAndKeepsCase() {
        expect(["10REM Hello", "20 ?=5", "0", "#=1"], "#=1\n5\n>")
        expect(["10REM Hello", "0"], "0\n10REM Hello\n>")
    }

    func testForNextLoop() {
        expect(["10 I=1,5 ?=I @=I+1", "20 / \"END\"", "#=1"], "#=1\n12345\nEND\n>")
    }

    func testForWithNegativeRange() {
        expect(["10 I=-2,2 ?=I .=1 @=I+1", "#=1"], "#=1\n-2 -1 0 1 2 \n>")
    }

    func testDoUntilLoop() {
        expect(["10 K=0 @ K=K+3 @=(K>10)", "20 ?=K", "#=1"], "#=1\n12\n>")
    }

    func testNestedLoops() {
        expect(["10 I=1,3 J=1,2 ?=I*10+J .=1 @=J+1 @=I+1", "#=1"], "#=1\n11 12 21 22 31 32 \n>")
    }

    func testGotoIfGosubReturnAndEnd() {
        expect([
            "10 N=0",
            "20 !=100",
            "30 ;=N<3 #=20",
            "40 \"DONE\" #=-1",
            "50 \"NOT REACHED\"",
            "100 N=N+1 ?=N ]",
            "#=1",
        ], "#=1\n123DONE\n>")
    }

    func testGotoMissingLineGoesToNextLarger() {
        expect(["10 ?=1", "30 ?=3", "#=20"], "#=20\n3\n>")
    }

    func testIfFalseInDirectModeEndsLine() {
        expect([";=0 ?=1"], ";=0 ?=1\n>")
    }

    func testErrorShowsLineNumber() {
        expect(["10 ?=1", "20 ?=)", "#=1"], "#=1\n1\nERR 20\n>")
    }

    func testReturnWithoutGosubIsAnError() {
        expect(["]"], "]\nERR\n>")
    }

    // MARK: システム

    func testNewClearsProgram() {
        expect(["10 ?=1", "&=0", "0"], "0\n>")
    }

    func testSpecialRegisters() {
        expect(["10 ?=1", "??== ??=& ??=*"], "??== ??=& ??=*\n060006087FFF\n>")
    }

    func testLockedProgramRejectsEdits() {
        expect(["10 ?=1", "&:0)=$F0", "20 ?=2"], "20 ?=2\nERR\n>")
    }

    func testChangeProgramAndSearchEnd() {
        expect([
            "10 \"ONE\"",
            "=$1000 &=0",
            "10 \"TWO\"",
            "#=1",
            "=$600",
            "#=1",
        ], "#=1\nONE\n>")
    }

    func testRandomIsWithinRange() {
        let text = run([
            "10 '=1234 I=1,50 R='6",
            "20 ;=R<1 \"BAD\"",
            "30 ;=R>6 \"BAD\"",
            "40 @=I+1 \"OK\"",
            "#=1",
        ])
        XCTAssertTrue(text.hasSuffix("OK\n>"), text)
        XCTAssertFalse(text.contains("BAD"), text)
    }

    /// 乱数の列は GAME65G と同じ xorshift(7、9、8)で決まる。
    func testRandomSequenceMatchesXorshift() {
        var seed: UInt16 = 0xACE1
        var expected = ""
        for _ in 0..<5 {
            expected += String(Arithmetic.random(n: 100, seed: &seed)) + " "
        }
        XCTAssertEqual(run(["I=1,5 ?='100 .=1 @=I+1"]), "I=1,5 ?='100 .=1 @=I+1\n" + expected + "\n>")
    }

    /// CALL(>=)は廃止したので、常にエラーになる。
    func testCallIsAbolished() {
        expect([">=$300 ?=1"], ">=$300 ?=1\nERR\n>")
    }

    // MARK: 入力

    func testNumericInputEvaluatesExpression() {
        var lines = ["A=? ?=A*2", "3+4"][...]
        let console = session { c in
            guard let line = lines.popFirst() else { return false }
            c.send(line + "\r")
            return true
        }
        XCTAssertEqual(console.text, ">A=? ?=A*2\n3+4\n14\n>")
    }

    func testCharacterInputDoesNotWait() {
        expect(["A=$ ?=A"], "A=$ ?=A\n0\n>")
        // キーが届いていれば文字コード
        expect(["10 @ K=$ @=(K<>0)", "20 ?=K", "#=1"], later: "x", "#=1\n120\n>")
    }

    func testCtrlCBreaksRunningProgram() {
        expect(["10 #=10", "#=1"], later: "\u{03}", "#=1\nBRK 10\n>")
    }

    /// LIST や実行の間に先打ちした行が欠けない(貼り付けを想定)。
    func testTypeAheadDuringListAndRun() {
        var numbers = ""
        for i in 1...20 { numbers += "\(i) " }
        expect(["10 I=1,20 ?=I .=1 @=I+1", "20 ?=99", "0\r#=1\r??=$ABCD"],
               "0\n10 I=1,20 ?=I .=1 @=I+1\n20 ?=99\n>#=1\n" + numbers + "99\n>??=$ABCD\nABCD\n>")
    }

    /// Ctrl-C は先打ちのキーより後ろにあっても効き、先打ちは捨てる。
    func testCtrlCAfterTypeAhead() {
        expect(["10 #=10", "#=1"], later: "abc\u{03}?=5\r", "#=1\nBRK 10\n>?=5\n5\n>")
    }

    func testBackspaceEditsLine() {
        expect(["?=12\u{08}3"], "?=12\u{08} \u{08}3\n13\n>")
    }

    /// 先打ちは 64 文字で捨てずに、全部ためる(設計書 M16)。
    func testLongTypeAheadIsKept() {
        let many = (1...30).map { "?=\($0)" }.joined(separator: "\r")
        let text = run(["10 I=1,200 @=I+1", "#=1\r" + many])
        XCTAssertTrue(text.hasSuffix(">?=30\n30\n>"), text)
    }

    // MARK: GAME65G.ja.md の例

    func testDocMultiplicationTable() {
        let text = run(["10 I=1,9", "20 J=1,9 ?(3)=I*J @=J+1", "30 / @=I+1", "#=1"])
        var rows: [String] = []
        for i in 1...9 {
            var row = ""
            for j in 1...9 {
                let digits = String(i * j)
                row += String(repeating: " ", count: 3 - digits.count) + digits
            }
            rows.append(row)
        }
        XCTAssertEqual(text, "#=1\n" + rows.joined(separator: "\n") + "\n>")
    }

    func testDocGuessingGame() {
        let program = [
            "10 \"PRESS A KEY\" / @ N='100 K=$ @=(K<>0)",
            "20 C=0",
            "30 \"1-100? \" G=? C=C+1",
            "40 ;=G<N \"UP\" / #=30",
            "50 ;=G>N \"DOWN\" / #=30",
            "60 \"OK \" ?=C / #=-1",
        ]
        var pending = program[...]
        var started = false
        var low = 1, high = 100, tries = 0
        var finished = false
        let console = session { c in
            if let line = pending.popFirst() {
                c.send(line + "\r")
                return true
            }
            if !started {
                started = true
                c.send("#=1\r ")
                return true
            }
            if finished { return false }
            let text = c.text
            if text.hasSuffix("OK \(tries)\n>") {
                finished = true
                return false
            }
            if text.hasSuffix("UP\n1-100? ") { low = (low + high) / 2 + 1 }
            if text.hasSuffix("DOWN\n1-100? ") { high = (low + high) / 2 - 1 }
            guard tries < 10 else { return false }
            tries += 1
            c.send("\((low + high) / 2)\r")
            return true
        }
        XCTAssertTrue(finished, console.text)
    }

    // MARK: asm から読み取った動き(設計書 §5)

    func testStatementsNeedNoSpaces() {
        expect(["\"AB\"/\"C\""], "\"AB\"/\"C\"\nAB\nC\n>")
    }

    func testSlashAfterExpressionIsDivision() {
        expect(["?=A/"], "?=A/\nERR\n>")
    }

    func testNegativeGotoEndsProgram() {
        expect(["10 ?=1 #=-5", "20 ?=2", "#=1"], "#=1\n1\n>")
        expect(["10 ?=1 #=99", "20 ?=2", "#=1"], "#=1\n1\n>")
    }

    func testGotoCommentLineGoesToNext() {
        expect(["10 #=20", "20REM", "30 ?=3", "#=1"], "#=1\n3\n>")
    }

    func testHexAfterDollarIsConstant() {
        expect(["?=$A+1"], "?=$A+1\n11\n>")
    }

    func testRemainderTakesTermFirst() {
        expect(["?=7/2 ?=%(9/4)"], "?=7/2 ?=%(9/4)\n31\n>")
    }

    func testReturnPopsLoopEntryToo() {
        // ] は段の種類を見ない。FOR の段を取り出して、その位置へ戻る。
        expect(["10 I=1,3 ?=I ]", "#=1"], "#=1\n11\nERR 10\n>")
    }

    func testStackOverflowIsAnError() {
        expect(["10 !=10", "#=1"], "#=1\nERR 10\n>")
    }

    func testOverflowInLoopCompareIsCorrected() {
        // 終値 32767 と値 -1 の比較は、引き算が溢れても正しく「32767 < -1 は偽」になり、ループを続ける
        expect(["10 K=0 I=1,32767 K=K+1 ;=K<3 @=-1", "20 ?=K", "#=1"], "#=1\n3\n>")
    }

    func testCommentLineKeepsLowercaseAfterNumber() {
        expect(["10rem x", "0"], "0\n10rem x\n>")
    }
}
