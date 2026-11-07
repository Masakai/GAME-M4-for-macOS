import Darwin
import Foundation

/// 標準入出力につなぐ入出力。端末なら raw モードにし、エコーはインタプリタが出す。
///
/// 入力は別のスレッドで読み、待ち行列にためる。端末では Ctrl-\ と Ctrl-D を入力の終わりにする。
public final class StdioConsole: GameConsole {
    private let queue = InputQueue()
    private var outBuffer: [UInt8] = []
    private var lastFlush = DispatchTime.now().uptimeNanoseconds
    private var original = termios()
    private let isTTY: Bool
    private var restored = false

    public init() {
        isTTY = isatty(STDIN_FILENO) != 0
        if isTTY {
            tcgetattr(STDIN_FILENO, &original)
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        outBuffer.reserveCapacity(4096)
        let queue = self.queue
        let tty = isTTY
        let thread = Thread {
            var normalizer = LineEndingNormalizer()
            var byte: UInt8 = 0
            var primed = false
            while true {
                if !primed {
                    // すぐ読める入力がなくなったら、起動の待ちを解く(ファイルなら最後まで読んでから)
                    var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    if poll(&p, 1, 0) == 0 {
                        primed = true
                        queue.markPrimed()
                    }
                }
                if Darwin.read(STDIN_FILENO, &byte, 1) != 1 { break }
                if tty && (byte == 0x1C || byte == 0x04) { break }
                if let b = normalizer.normalize(byte) { queue.append(b) }
            }
            queue.close()
        }
        thread.start()
        // 起動したときに届いていた入力は、読み終えてから始める(実行のたびに結果が変わらないように)
        queue.waitUntilPrimed()
    }

    deinit {
        restore()
    }

    /// 端末の設定を元に戻す。
    public func restore() {
        flush()
        if isTTY && !restored {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            restored = true
        }
    }

    public func write(_ byte: UInt8) {
        outBuffer.append(byte)
        if byte == 0x0A || outBuffer.count >= 4096 { flush() }
    }

    public func flush() {
        guard !outBuffer.isEmpty else { return }
        outBuffer.withUnsafeBufferPointer { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(STDOUT_FILENO, p.baseAddress! + offset, p.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        outBuffer.removeAll(keepingCapacity: true)
        lastFlush = DispatchTime.now().uptimeNanoseconds
    }

    public func read(wait: Bool) -> UInt8? {
        if let b = queue.read(wait: false) { return b }
        flush()
        return queue.read(wait: wait)
    }

    public var isInputExhausted: Bool { queue.isExhausted }

    public func takeBreak() -> Bool {
        // 改行のない出力も、10 ミリ秒ごとには画面に出す
        if !outBuffer.isEmpty && DispatchTime.now().uptimeNanoseconds - lastFlush > 10_000_000 {
            flush()
        }
        return queue.takeBreak()
    }
}
