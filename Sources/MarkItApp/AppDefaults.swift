import Foundation

/// Where the app keeps its preferences.
///
/// In normal use this is `com.debugly.markit` -- the real, long-lived store
/// holding bookmarks, WebDAV configuration and the encrypted credential
/// vault. Code must never write to it under any circumstance other than the
/// user actually running the app.
///
/// XCUITest is a different matter. The test runner launches the same installed
/// app, with the same bundle identifier, on the same machine, as the person
/// who uses it. A test that calls `removeObject` on the real defaults wipes
/// their root folder list and their WebDAV setup -- silently, and in a way that
/// only surfaces the next time they launch the app.
///
/// So a launch carrying `--uitest-suite <name>` is redirected to its own
/// suite, which the runner also wipes before each test. The production store is
/// never opened at all: not read, not written, not cleared.
enum AppDefaults {
    /// The production suite. Anything named this is the user's real data.
    static let productionSuite = "com.debugly.markit"

    /// Launch argument prefix that moves a run onto an isolated suite.
    static let suiteArgument = "--uitest-suite"

    /// The suite this process should read and write.
    ///
    /// Falls back to production when no argument is given, which is every real
    /// launch and every manual run from Xcode.
    static var suiteName: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: suiteArgument),
              arguments.count > index + 1 else {
            return productionSuite
        }
        let requested = arguments[index + 1]
        guard !requested.isEmpty else { return productionSuite }
        return requested
    }

    /// True when this process is running against something other than the
    /// user's real preferences.
    static var isIsolated: Bool {
        suiteName != productionSuite
    }

    /// Defaults for the current process.
    ///
    /// Note the ordering: an isolated suite must never fall back to `.standard`
    /// or to production, because that is exactly the leak this type exists to
    /// prevent. Failing loudly is better than silently touching real data.
    static func store() -> UserDefaults {
        if isIsolated {
            guard let isolated = UserDefaults(suiteName: suiteName) else {
                fatalError("UI test suite \(suiteName) is not a valid UserDefaults suite")
            }
            return isolated
        }
        return UserDefaults(suiteName: productionSuite) ?? .standard
    }
}