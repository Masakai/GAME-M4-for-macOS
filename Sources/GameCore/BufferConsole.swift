import Foundation

/// 出力をメモリにためる入出力。テストと、コンパイラの行の読み込みに使う。
public final class BufferConsole: GameConsole {
    public private(set) var output: [UInt8] = []
    public let input = InputQueue()
    /// 待つ読み出しで入力が空のときに呼ぶ。入力を足して true を返すと読み続ける。false なら入力の終わり。
    public var onNeedInput: ((BufferConsole) -> Bool)?

    public init(input text: String = "") {
        input.append(Array(text.utf8))
    }

    /// 出力の文字列(CR を除く)。
    public var text: String {
        String(decoding: output.filter { $0 != 0x0D }, as: UTF8.self)
    }

    public func clearOutput() {
        output.removeAll()
    }

    public func send(_ text: String) {
        input.append(Array(text.utf8))
    }

    private var delayed: [(polls: Int, bytes: [UInt8])] = []

    /// 中断の確認か待たない読み出しを polls 回したあとで、入力に足す(実行中に打ったキーを真似る)。
    public func sendLater(_ text: String, afterPolls polls: Int) {
        delayed.append((polls, Array(text.utf8)))
    }

    private func countPoll() {
        guard !delayed.isEmpty else { return }
        delayed[0].polls -= 1
        if delayed[0].polls <= 0 {
            input.append(delayed.removeFirst().bytes)
        }
    }

    public func write(_ byte: UInt8) {
        output.append(byte)
    }

    public func read(wait: Bool) -> UInt8? {
        if !wait { countPoll() }
        if let b = input.read(wait: false) { return b }
        guard wait else { return nil }
        while let handler = onNeedInput, handler(self) {
            if let b = input.read(wait: false) { return b }
        }
        return nil
    }

    /// 入力の待ち行列を close() したあと、読み残しがなければ true。
    public var isInputExhausted: Bool { input.isExhausted }

    public func takeBreak() -> Bool {
        countPoll()
        return input.takeBreak()
    }
}
