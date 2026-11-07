import AppKit
import SwiftUI

@main
struct GameM4App: App {
    @StateObject private var model = AppModel()

    init() {
        // swift run で動かしたときも、ふつうのアプリとして前に出す
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("GAME-M4", id: "main") {
            ContentView(model: model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規") { model.newDocument() }
                    .keyboardShortcut("n")
                Button("開く…") { model.open() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { model.save() }
                    .keyboardShortcut("s")
                Button("別名で保存…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("プログラム") {
                Button("実行") { model.run() }
                    .keyboardShortcut("r")
                Button("インタプリタに読み込む") { model.loadIntoInterpreter() }
                    .keyboardShortcut("l")
                Divider()
                Button("コンパイルして実行") { model.compileAndRun() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isCompiling)
                Button("コンパイルして保存…") { model.compileToFile() }
                    .keyboardShortcut("b")
                    .disabled(model.isCompiling)
                Divider()
                Button("止める") { model.stop() }
                    .keyboardShortcut(".")
                Button("端末を消去") { model.clearTerminal() }
                    .keyboardShortcut("k")
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                CodeEditor(text: $model.source)
                    .frame(minWidth: 280, idealWidth: 420)
                TerminalView(model: model)
                    .frame(minWidth: 380, idealWidth: 640)
            }
            Divider()
            HStack {
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if model.isCompiling { ProgressView().controlSize(.small) }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .navigationTitle(model.windowTitle)
        .toolbar {
            ToolbarItemGroup {
                Button { model.run() } label: {
                    Label("実行", systemImage: "play.fill")
                }
                .help("インタプリタで実行(⌘R)")
                Button { model.compileAndRun() } label: {
                    Label("コンパイルして実行", systemImage: "hammer.fill")
                }
                .help("ARM64 にコンパイルして実行(⇧⌘R)")
                .disabled(model.isCompiling)
                Button { model.stop() } label: {
                    Label("止める", systemImage: "stop.fill")
                }
                .help("実行を止める(⌘.)")
            }
        }
    }
}
