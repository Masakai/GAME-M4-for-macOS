import AppKit
import Foundation
import GameCompiler
import GameCore
import SwiftUI
import UniformTypeIdentifiers

/// アプリの状態。エディタのプログラム、ファイル、端末、インタプリタ、コンパイルしたプログラムの子プロセス。
@MainActor
final class AppModel: ObservableObject {
    @Published var source: String {
        didSet { if source != oldValue { isDirty = true } }
    }
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var status = "準備完了"
    @Published private(set) var isCompiling = false
    @Published private(set) var isRunningCompiled = false

    weak var terminalTextView: NSTextView?

    private let screen = TerminalScreen()
    private let session: InterpreterSession
    private var child: Process?
    private var childInput: FileHandle?
    private var refreshTimer: Timer?

    static let gameType = UTType(filenameExtension: "gam", conformingTo: .plainText) ?? .plainText

    /// 最初にエディタに出すプログラム(examples/mandel.gam と同じ)。
    /// インタプリタで約 3.4 秒、コンパイルすると約 0.04 秒かかる(M4、2026-11-07 に CLI で測った)。
    static let sample = """
    10REM マンデルブロ集合(16 ビットの固定小数点。64 が 1.0)
    20REM M は 1 点あたりの反復の上限。大きくするほど時間がかかる
    30 T=$7000 T:0)=32 T:1)=46 T:2)=44 T:3)=45 T:4)=126 T:5)=58 T:6)=59 T:7)=61 T:8)=33 T:9)=42
    40 M=20000
    50 Y=-12,12
    60 X=-32,31 C=X*7/2-40 D=Y*11 A=0 B=0 N=0
    70 ;=A>128 #=110
    72 ;=A<-128 #=110
    74 ;=B>128 #=110
    76 ;=B<-128 #=110
    80 P=A*A/64 Q=B*B/64 ;=P+Q>256 #=110
    90 B=A*B/32+D A=P-Q+C N=N+1 ;=N<M #=70
    100 "#" #=120
    110 $=T:N-(N/10*10))
    120 @=X+1
    130 / @=Y+1

    """

    init() {
        source = Self.sample
        let screen = self.screen
        session = InterpreterSession(sink: { screen.enqueue($0) })
        isDirty = false
        signal(SIGPIPE, SIG_IGN)         // 終わった子プロセスのパイプに書いても落ちないように
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTerminal() }
        }
    }

    var windowTitle: String {
        let name = fileURL?.lastPathComponent ?? "名称未設定.gam"
        return isDirty ? "\(name) — 編集済み" : name
    }

    // MARK: 端末

    private func refreshTerminal() {
        guard let view = terminalTextView, let text = screen.drain() else { return }
        view.string = text
        view.scrollToEndOfDocument(nil)
    }

    func sendKeys(_ bytes: [UInt8]) {
        if let childInput {
            try? childInput.write(contentsOf: Data(bytes))
        } else {
            session.send(bytes)
        }
    }

    func clearTerminal() {
        screen.clear()
        terminalTextView?.string = ""
        screen.enqueue(0x0D)             // 次の描画で空の画面を出す
    }

    func focusTerminal() {
        if let view = terminalTextView { view.window?.makeFirstResponder(view) }
    }

    // MARK: 実行

    /// エディタのプログラムをインタプリタに読み込み直して、#=1 で実行する。
    func run() {
        stopCompiled()
        session.run(source: source)
        status = "インタプリタで実行"
        focusTerminal()
    }

    /// エディタのプログラムをインタプリタに読み込む(実行しない)。
    func loadIntoInterpreter() {
        stopCompiled()
        session.load(source: source)
        status = "インタプリタに読み込んだ。端末で 0 を入れると一覧、#=1 で実行"
        focusTerminal()
    }

    /// 実行を止める(Ctrl-C と同じ)。
    func stop() {
        if let childInput {
            try? childInput.write(contentsOf: Data([0x03]))
        } else {
            session.stop()
        }
    }

    // MARK: コンパイル

    /// コンパイルして、子プロセスとして動かす。入出力は端末につなぐ。
    func compileAndRun() {
        guard !isCompiling else { return }
        stopCompiled()
        session.perform { _ in }         // インタプリタで動いているプログラムを止める
        let exe = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamem4-run-\(UUID().uuidString)")
        compile(to: exe) { [weak self] in self?.startCompiled(exe) }
    }

    /// コンパイルして、実行ファイルを保存する。
    func compileToFile() {
        guard !isCompiling else { return }
        let panel = NSSavePanel()
        panel.title = "実行ファイルの保存先"
        panel.nameFieldStringValue = fileURL?.deletingPathExtension().lastPathComponent ?? "program"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compile(to: url) { [weak self] in
            self?.status = "コンパイルした: \(url.path)"
        }
    }

    private func compile(to output: URL, then done: @escaping () -> Void) {
        isCompiling = true
        status = "コンパイル中…"
        let source = self.source
        Task.detached {
            let result: Error?
            do {
                try GameCompiler.build(source: source, output: output)
                result = nil
            } catch {
                result = error
            }
            await MainActor.run {
                self.isCompiling = false
                if let result {
                    self.showCompileError(result)
                } else {
                    done()
                }
            }
        }
    }

    private func showCompileError(_ error: Error) {
        let text = (error as? CompileError)?.description ?? "\(error)"
        status = "コンパイルできない: " + (text.split(separator: "\n").first.map(String.init) ?? "")
        let alert = NSAlert()
        alert.messageText = "コンパイルできない"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func startCompiled(_ exe: URL) {
        let process = Process()
        process.executableURL = exe
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let screen = self.screen
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                screen.enqueue(data)
            }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.compiledEnded(code, exe: exe) }
        }
        do {
            screen.enqueue(0x0D)
            screen.enqueue(0x0A)
            try process.run()
        } catch {
            status = "動かせない: \(error.localizedDescription)"
            return
        }
        child = process
        childInput = input.fileHandleForWriting
        isRunningCompiled = true
        status = "コンパイルしたプログラムを実行中"
        focusTerminal()
    }

    private func compiledEnded(_ code: Int32, exe: URL) {
        child = nil
        childInput = nil
        isRunningCompiled = false
        try? FileManager.default.removeItem(at: exe)
        switch code {
        case 0: status = "コンパイルしたプログラムが終わった"
        case 1: status = "コンパイルしたプログラムがエラーで止まった(終了コード 1)"
        case 130: status = "コンパイルしたプログラムを中断した(終了コード 130)"
        default: status = "コンパイルしたプログラムが終わった(終了コード \(code))"
        }
        session.reprompt()
    }

    private func stopCompiled() {
        if let child, child.isRunning {
            child.terminate()
        }
    }

    // MARK: ファイル

    private func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "編集中のプログラムを保存しますか?"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newDocument() {
        guard confirmDiscard() else { return }
        source = ""
        fileURL = nil
        isDirty = false
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.gameType, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            source = String(decoding: data, as: UTF8.self)
            fileURL = url
            isDirty = false
            status = "開いた: \(url.lastPathComponent)"
        } catch {
            status = "開けない: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.gameType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "program.gam"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try Data(source.utf8).write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            status = "保存した: \(url.lastPathComponent)"
            return true
        } catch {
            status = "保存できない: \(error.localizedDescription)"
            return false
        }
    }
}
