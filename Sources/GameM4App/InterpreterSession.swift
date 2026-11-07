import Foundation
import GameCore

/// GUI の端末につなぐ入出力。出力は端末の受け皿に送り、入力は待ち行列から読む。
final class GUIConsole: GameConsole {
    let queue = InputQueue()
    private let sink: (UInt8) -> Void

    init(sink: @escaping (UInt8) -> Void) {
        self.sink = sink
    }

    func write(_ byte: UInt8) { sink(byte) }
    func read(wait: Bool) -> UInt8? { queue.read(wait: wait) }
    func takeBreak() -> Bool { queue.takeBreak() }
    var isInputExhausted: Bool { false }
}

/// インタプリタを専用のスレッドで動かす。端末から打った行は、ふつうに対話モードで実行する。
/// エディタのプログラムの実行は、割り込んでプロンプトへ戻してから、このスレッドで行う。
final class InterpreterSession: @unchecked Sendable {
    let console: GUIConsole
    private let interp: Interpreter
    private let lock = NSLock()
    private var pending: [(Interpreter) -> Void] = []

    init(sink: @escaping (UInt8) -> Void) {
        console = GUIConsole(sink: sink)
        interp = Interpreter(console: console)
        let thread = Thread { [self] in self.main() }
        thread.stackSize = 8 << 20
        thread.start()
    }

    private func main() {
        interp.coldStart()
        while true {
            interp.repl()                // 割り込まれると戻る
            lock.lock()
            let actions = pending
            pending.removeAll()
            lock.unlock()
            for action in actions { action(interp) }
        }
    }

    /// 端末で打ったキー。
    func send(_ bytes: [UInt8]) {
        console.queue.append(bytes)
    }

    /// 実行中のプログラムを止めて(BRK)、プロンプトへ戻す。
    func stop() {
        console.queue.append(0x03)
    }

    /// 割り込んでから、インタプリタのスレッドで action を実行する。そのあとプロンプトに戻る。
    func perform(_ action: @escaping (Interpreter) -> Void) {
        lock.lock()
        pending.append(action)
        lock.unlock()
        console.queue.clear()
        console.queue.interrupt()
    }

    /// エディタのプログラムを読み込み直して、#=1 で実行する。
    func run(source: String) {
        perform { interp in
            interp.newLineIfNeeded()
            interp.coldStart(showBanner: false)
            for line in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let bytes = Array(line.utf8)
                if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                interp.enterLine(bytes)
            }
            interp.run(from: 1)
        }
    }

    /// エディタのプログラムを読み込むだけにする(実行しない)。
    func load(source: String) {
        perform { interp in
            interp.newLineIfNeeded()
            interp.coldStart(showBanner: false)
            for line in source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
                let bytes = Array(line.utf8)
                if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                interp.enterLine(bytes)
            }
        }
    }

    /// プロンプトを出し直す(コンパイルしたプログラムが終わったあと)。
    func reprompt() {
        perform { interp in interp.newLineIfNeeded() }
    }

    /// 端末に、プログラムの外からの知らせを出す(インタプリタのスレッドで、行頭に出す)。
    func notice(_ text: String) {
        perform { interp in
            interp.newLineIfNeeded()
            for b in text.utf8 { interp.console.write(b) }
            interp.console.write(0x0D)
            interp.console.write(0x0A)
        }
    }
}
