import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.document.confirmCloseIfNeeded() ? .terminateNow : .terminateCancel
    }
}

@main
struct MarkItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        appDelegate.appState = state
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
