import Foundation

/// インタプリタの入出力。端末、GUI、テストがそれぞれ実装する。
public protocol GameConsole: AnyObject {
    /// 1 バイト出力する。
    func write(_ byte: UInt8)
    /// 1 バイト読む。wait が true なら届くまで待つ。
    /// 待たないときにキーがなければ nil。待つときに nil を返したら入力の終わり。
    func read(wait: Bool) -> UInt8?
    /// 入力に Ctrl-C($03)があれば、それまでの入力とともに取り除いて true を返す。
    func takeBreak() -> Bool
    /// 入力が終わり、読み残しもなければ true(パイプやファイルから読むとき)。
    /// `$` の待たない入力は、このとき空回りせずに実行を終える。
    var isInputExhausted: Bool { get }
}

/// 入力の行末を CR にそろえる。CR LF は CR 1 つに、LF だけなら CR にする。
public struct LineEndingNormalizer {
    private var lastWasCR = false

    public init() {}

    /// 変換後のバイトを返す。捨てるときは nil。
    public mutating func normalize(_ byte: UInt8) -> UInt8? {
        defer { lastWasCR = (byte == 0x0D) }
        if byte == 0x0A {
            return lastWasCR ? nil : 0x0D
        }
        return byte
    }
}

/// スレッド間で共有する入力の待ち行列。Ctrl-C の数を数えておき、中断の確認を軽くする。
/// 先打ちのキーは捨てずに全部ためる(設計書 M16)。
public final class InputQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var bytes: [UInt8] = []
    private var head = 0
    private var breaks = 0
    private var closed = false
    private var primed = false

    public init() {}

    /// 入力を足す。
    public func append(_ data: [UInt8]) {
        condition.lock()
        for b in data {
            bytes.append(b)
            if b == 0x03 { breaks += 1 }
        }
        condition.broadcast()
        condition.unlock()
    }

    public func append(_ byte: UInt8) {
        append([byte])
    }

    /// 入力の終わりを知らせる。待っている読み出しは nil を返す。
    public func close() {
        condition.lock()
        closed = true
        primed = true
        condition.broadcast()
        condition.unlock()
    }

    /// 起動時に届いていた入力を読み終えたことを知らせる。
    public func markPrimed() {
        condition.lock()
        primed = true
        condition.broadcast()
        condition.unlock()
    }

    /// markPrimed か close が呼ばれるまで待つ。
    public func waitUntilPrimed() {
        condition.lock()
        while !primed { condition.wait() }
        condition.unlock()
    }

    /// 入力が終わり、読み残しもなければ true。
    public var isExhausted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed && head >= bytes.count
    }

    private var interrupted = false

    /// 実行を止めてプロンプトへ戻し、そこで待っている読み出しを 1 度だけ nil で返す(GUI で使う)。
    /// 実行中なら、次の中断の確認で止まる(BRK)。
    public func interrupt() {
        condition.lock()
        interrupted = true
        condition.broadcast()
        condition.unlock()
    }

    /// ためた入力をすべて捨てる。
    public func clear() {
        condition.lock()
        bytes.removeAll()
        head = 0
        breaks = 0
        condition.unlock()
    }

    public func read(wait: Bool) -> UInt8? {
        condition.lock()
        defer { condition.unlock() }
        if wait && interrupted {
            interrupted = false
            return nil
        }
        while head >= bytes.count {
            if !wait || closed { return nil }
            condition.wait()
            if interrupted {
                interrupted = false
                return nil
            }
        }
        let b = bytes[head]
        head += 1
        if b == 0x03 { breaks -= 1 }
        compact()
        return b
    }

    public func takeBreak() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if interrupted { return true }
        guard breaks > 0 else { return false }
        while head < bytes.count {
            let b = bytes[head]
            head += 1
            if b == 0x03 {
                breaks -= 1
                break
            }
        }
        compact()
        return true
    }

    /// 読み終えた部分が大きくなったら詰める。
    private func compact() {
        if head > 4096 && head * 2 > bytes.count {
            bytes.removeFirst(head)
            head = 0
        }
    }
}
