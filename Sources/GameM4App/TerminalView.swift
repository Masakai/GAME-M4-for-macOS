import AppKit
import SwiftUI

/// 端末の画面。CR、LF、BS だけを解釈する文字の並び(Glow65 の TerminalModel を元にした)。
/// UTF-8 の文字は、そろってから 1 文字として置く。
final class TerminalScreen: @unchecked Sendable {
    private var lines: [[Character]] = [[]]
    private var column = 0
    private let maxLines = 2000
    private var pendingUTF8: [UInt8] = []

    /// 別のスレッドから送られてくるバイトの受け皿(ロック保護)。
    private var inbox: [UInt8] = []
    private let lock = NSLock()

    func enqueue(_ byte: UInt8) {
        lock.lock()
        inbox.append(byte)
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        lock.lock()
        inbox.append(contentsOf: data)
        lock.unlock()
    }

    /// たまった出力を画面に反映する。変わらなければ nil。
    func drain() -> String? {
        lock.lock()
        let bytes = inbox
        inbox.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !bytes.isEmpty else { return nil }
        for b in bytes { process(b) }
        return lines.map { String($0) }.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        inbox.removeAll()
        lock.unlock()
        lines = [[]]
        column = 0
    }

    private func process(_ byte: UInt8) {
        if !pendingUTF8.isEmpty || byte >= 0x80 {
            pendingUTF8.append(byte)
            if let s = String(bytes: pendingUTF8, encoding: .utf8), let ch = s.first {
                pendingUTF8.removeAll()
                put(ch)
            } else if pendingUTF8.count >= 4 {
                pendingUTF8.removeAll()
                put("?")
            }
            return
        }
        switch byte {
        case 0x0D:
            column = 0
        case 0x0A:
            lines.append([])
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            if column > 0 { lines[lines.count - 1] = [Character](repeating: " ", count: column) }
        case 0x08, 0x7F:
            if column > 0 { column -= 1 }
        case 0x20...0x7E:
            put(Character(UnicodeScalar(byte)))
        default:
            break
        }
    }

    private func put(_ ch: Character) {
        var line = lines[lines.count - 1]
        while line.count < column { line.append(" ") }
        if column < line.count {
            line[column] = ch
        } else {
            line.append(ch)
        }
        lines[lines.count - 1] = line
        column += 1
    }
}

/// キーを受け取る、読むだけの NSTextView。
final class TerminalTextView: NSTextView {
    var onBytes: (([UInt8]) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers?.lowercased(),
           let scalar = chars.unicodeScalars.first, scalar.value >= 0x61, scalar.value <= 0x7A {
            onBytes?([UInt8(scalar.value - 0x60)])      // Ctrl-A は $01、Ctrl-C は $03
            return
        }
        switch event.keyCode {
        case 36, 76: onBytes?([0x0D])                    // Return、Enter
        case 51: onBytes?([0x08])                        // Delete(後退)
        case 53: onBytes?([0x1B])                        // Esc
        default:
            if let chars = event.characters, !chars.isEmpty {
                onBytes?(Array(chars.utf8))
            }
        }
    }

    /// 貼り付けた文字列は、打ち込んだのと同じに送る(行末は CR)。
    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var bytes: [UInt8] = []
        var lastCR = false
        for b in text.utf8 {
            if b == 0x0A {
                if !lastCR { bytes.append(0x0D) }
                lastCR = false
                continue
            }
            lastCR = (b == 0x0D)
            bytes.append(b)
        }
        onBytes?(bytes)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

/// 端末の表示。
struct TerminalView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TerminalTextView.scrollableTextView()
        let old = scroll.documentView as! NSTextView
        let text = TerminalTextView(frame: old.frame, textContainer: old.textContainer)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.6, alpha: 1)
        text.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        text.insertionPointColor = .clear
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.onBytes = { [weak model] bytes in
            Task { @MainActor in model?.sendKeys(bytes) }
        }
        scroll.documentView = text
        scroll.drawsBackground = true
        scroll.backgroundColor = text.backgroundColor
        model.terminalTextView = text
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
