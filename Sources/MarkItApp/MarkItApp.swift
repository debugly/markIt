import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var onOpenFile: ((URL) -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.document.confirmCloseIfNeeded() ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        onOpenFile?(url)
    }
}

@main
struct MarkItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        appDelegate.appState = state
        appDelegate.onOpenFile = { [weak state] url in
            guard let state else { return }
            DispatchQueue.main.async {
                if state.document.url == url {
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                } else {
                    state.openFile(url)
                }
            }
        }

        if let url = Self.getInitialFileURL() {
            DispatchQueue.main.async {
                state.openFile(url)
            }
        }
    }

    private static func getInitialFileURL() -> URL? {
        let args = CommandLine.arguments
        guard args.count > 1 else { return nil }
        let path = args[1]
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 980, minHeight: 640)
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建文件") {
                    state.createNewFile()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("打开文件...") {
                    state.openFilePanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("打开文件夹...") {
                    state.promptOpenFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("导出 HTML...") {
                    state.exportHTML()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.document.url == nil)

                Divider()

                Menu("最近打开") {
                    ForEach(state.recentFiles, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            state.openFile(url)
                        }
                    }
                    if !state.recentFiles.isEmpty {
                        Divider()
                        Button("清除最近文件") {
                            state.clearRecentFiles()
                        }
                    }
                }
                .disabled(state.recentFiles.isEmpty)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
