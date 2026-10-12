//
//  MarkitUITests.swift
//  MarkitUITests
//
//  XCUITest (macOS) 对 MarkIt 核心功能的端到端测试。
//  依赖 app 侧新增的无障碍标识符 (accessibility identifier)，见各 UI 源文件与 agent.md。
//

import XCTest

final class MarkitUITests: XCTestCase {

    private var fixtureDirectory: URL!
    private var textFixtureURL: URL!
    private var markdownFixtureURL: URL!

    // MARK: - Fixture 生命周期

    override func setUpWithError() throws {
        continueAfterFailure = false

        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkitUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        textFixtureURL = fixtureDirectory.appendingPathComponent("sample.txt")
        try "Hello MarkIt\nThis is a plain text fixture.".write(
            to: textFixtureURL, atomically: true, encoding: .utf8)

        markdownFixtureURL = fixtureDirectory.appendingPathComponent("sample.md")
        try "# 标题\n\n这是一段 Markdown **加粗** 内容。\n".write(
            to: markdownFixtureURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
    }

    // MARK: - 工具

    /// 以 `--uitest-reset` 启动，保证每次测试都从确定性的空状态开始。
    ///
    /// Suite backing the next launch, unique per test.
    ///
    /// Each test gets its own because a suite name is a UserDefaults domain
    /// that outlives the process: reusing one would let state bleed between
    /// tests, and wiping a shared one would only be safe as long as no real
    /// data ever landed there.
    private var nextSuiteName: String {
        suiteCounter += 1
        return "com.debugly.markit.uitest.\(ProcessInfo.processInfo.processIdentifier).\(suiteCounter)"
    }

    private var suiteCounter = 0

    /// Launches the app against an isolated preferences suite.
    ///
    /// `--uitest-suite` is what keeps a test run away from the real
    /// com.debugly.markit store. `--uitest-reset` on its own would clear the
    /// user's bookmarks and recent files; AppState refuses to run it without a
    /// suite, so these two arguments travel together by construction.
    func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitest-reset",
            "--uitest-suite", nextSuiteName
        ] + arguments
        app.launch()
        return app
    }

    /// 打开偏好设置窗口（通过菜单栏，比 ⌘, 更稳定）。
    private func openPreferences(_ app: XCUIApplication) {
        app.menuBars.menuBarItems["Markit"].click()
        let prefsItem = app.menuItems["偏好设置..."]
        _ = prefsItem.waitForExistence(timeout: 5)
        prefsItem.click()
    }

    // MARK: - 测试

    /// ⌘S 保存：有改动时写盘并提示，无改动时说明已是最新。
    ///
    /// Autosave makes the manual save a no-op most of the time, so the
    /// assertion that matters is the feedback: a keypress with no response
    /// reads as a broken shortcut rather than as "already saved".
    func testCommandSSavesAndReports() {
        let app = launchApp(arguments: [markdownFixtureURL.path])

        let stats = app.staticTexts["statsLabel"]
        XCTAssertTrue(stats.waitForExistence(timeout: 15), "字数统计应出现")

        // No edits yet: saving should say so rather than look swallowed.
        app.typeKey("s", modifierFlags: .command)

        let upToDate = NSPredicate(format: "value CONTAINS %@", "无需保存")
        expectation(for: upToDate, evaluatedWith: stats)
        waitForExpectations(timeout: 5)

        // The confirmation clears itself, putting the counts back.
        let backToCounts = NSPredicate(format: "value CONTAINS %@", "行")
        expectation(for: backToCounts, evaluatedWith: stats)
        waitForExpectations(timeout: 6)

        // The menu item shows up where shortcuts are looked up, and is enabled
        // with a document open. The shortcut itself is verified by the keypress
        // above -- macOS XCUIElement exposes no keyEquivalent to assert on.
        app.menuBars.menuBarItems["文件"].click()
        let saveItem = app.menuItems["保存"]
        XCTAssertTrue(saveItem.waitForExistence(timeout: 5), "「保存」菜单项应存在")
        XCTAssertTrue(saveItem.isEnabled, "打开文档后「保存」应可用")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// 1. 应用能正常启动，主窗口 + 侧边栏 + 占位内容可见。
    func testAppLaunchesWithMainWindowAndPlaceholder() {
        let app = launchApp()

        XCTAssertTrue(app.searchFields["sidebarFilterField"].waitForExistence(timeout: 15),
                      "侧边栏过滤输入框应存在")
        XCTAssertTrue(app.outlines["sidebarOutline"].waitForExistence(timeout: 5),
                      "侧边栏文件列表应存在")
        XCTAssertTrue(app.staticTexts["placeholderTitle"].waitForExistence(timeout: 5),
                      "空状态占位标题应存在")
        XCTAssertEqual(app.staticTexts["placeholderTitle"].value as? String, "无打开的文件")
        XCTAssertTrue(app.staticTexts["titleLabel"].exists, "工具栏标题应存在")
        XCTAssertEqual(app.staticTexts["titleLabel"].value as? String, "未命名")
    }

    /// 2. 打开 Markdown 文件后，工具栏出现模式切换按钮与字数统计。
    func testMarkdownFileExposesToolbarControls() {
        let app = launchApp(arguments: [markdownFixtureURL.path])

        let modeButton = app.buttons["editModeButton"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 15), "模式切换按钮应出现")

        XCTAssertTrue(app.staticTexts["statsLabel"].waitForExistence(timeout: 5),
                      "字数统计应出现")
        let stats = (app.staticTexts["statsLabel"].value as? String) ?? ""
        XCTAssertTrue(stats.contains("行") && stats.contains("字"),
                      "字数统计应包含行数与字数，实际为: \(stats)")

        XCTAssertTrue(app.buttons["sidebarToggleButton"].exists, "侧边栏切换按钮应存在")
    }

    /// 3. 打开纯文本文件默认进入源码编辑模式，可输入并回读内容。
    func testEditPlainTextInSourceEditor() {
        let app = launchApp(arguments: [textFixtureURL.path])

        let editor = app.textViews["sourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "源码编辑器应存在")

        let initialValue = editor.value as? String ?? ""
        XCTAssertTrue(initialValue.contains("Hello MarkIt"),
                      "源码编辑器应显示文件内容，实际为: \(initialValue)")

        editor.click()
        editor.typeText(" edited")

        let updatedValue = editor.value as? String ?? ""
        XCTAssertTrue(updatedValue.contains("Hello MarkIt") && updatedValue.contains(" edited"),
                      "输入后内容应被追加，实际为: \(updatedValue)")
    }

    /// 4. Markdown 默认进入所见即所得模式，点击模式按钮可切到源码编辑器。
    func testToggleMarkdownEditModeToSource() {
        let app = launchApp(arguments: [markdownFixtureURL.path])

        // WKWebView 的无障碍标识符落在包裹它的 Group 上，用任意类型查询最稳。
        XCTAssertTrue(app.groups["editorWebView"].waitForExistence(timeout: 15),
                      "所见即所得编辑器 (WebView 容器) 应存在")

        let modeButton = app.buttons["editModeButton"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 5))
        modeButton.click()

        XCTAssertTrue(app.textViews["sourceEditor"].waitForExistence(timeout: 10),
                      "点击模式按钮后应切换到源码编辑器")
    }

    /// 5. 偏好设置窗口可通过菜单栏打开，并暴露选项卡与通用设置项。
    func testOpenPreferencesWindow() {
        let app = launchApp()
        XCTAssertTrue(app.searchFields["sidebarFilterField"].waitForExistence(timeout: 15))

        openPreferences(app)

        let tabControl = app.descendants(matching: .any)["prefsTabControl"]
        XCTAssertTrue(tabControl.waitForExistence(timeout: 10), "偏好设置选项卡应存在")
        XCTAssertTrue(app.checkBoxes["inspectCheck"].waitForExistence(timeout: 5),
                      "通用选项卡的 WebView 审查工具复选框应存在")
    }

    /// 6. 侧边栏过滤框可聚焦并输入内容。
    func testSidebarFilterFieldAcceptsInput() {
        let app = launchApp(arguments: [markdownFixtureURL.path])

        let filterField = app.searchFields["sidebarFilterField"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 15), "过滤框应存在")

        filterField.click()
        filterField.typeText("sample")

        let value = filterField.value as? String ?? ""
        XCTAssertTrue(value.contains("sample"), "过滤框应包含输入内容，实际为: \(value)")
    }
}
