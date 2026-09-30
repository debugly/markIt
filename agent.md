# agent.md — MarkIt 项目约定

## 沟通语言
- 与用户沟通一律使用中文。

## 项目概览
- MarkIt 是一个 macOS 原生 Markdown 编辑器（AppKit，Swift），支持 WYSIWYG（Tiptap/ProseMirror）与源码两种编辑模式，以及 WebDAV 同步、文件树侧边栏。
- 项目用 XcodeGen 生成 `.xcodeproj`（`*.xcodeproj/` 已被 gitignore），**工程配置的唯一事实来源是 `project.yml`**。改完 `project.yml` 或增删源文件后必须运行 `xcodegen generate` 重新生成工程，否则新文件不会被编译。

## 构建 / 测试
- 生成工程：`xcodegen generate`
- 构建 App：`xcodebuild build -project Markit.xcodeproj -scheme Markit -destination 'platform=macOS'`
- 编译并运行 UI 测试：
  `xcodebuild test -project Markit.xcodeproj -scheme Markit -destination 'platform=macOS' -derivedDataPath ./.build/DerivedData`
- 单独跑某个测试：`-only-testing:MarkitUITests/MarkitUITests/<方法名>`

## UI 测试（XCUITest，macOS）
- UI 测试目标 `MarkitUITests` 位于 `MarkitUITests/`，通过 `TEST_TARGET_NAME: Markit` 关联 App。
- 测试用 `--uitest-reset` 启动参数让 `AppState` 跳过书签/最近文件/上次打开文件的恢复，保证每次测试从空状态开始。
- 用临时目录 + launchArgument 传文件路径来打开被测文件（App 的 `getInitialFileURL()` 会读取命令行参数中的文件路径）。

## 无障碍（Accessibility）约定
- 关键控件统一用 `setAccessibilityIdentifier(_:)` 暴露稳定标识符，供 XCUITest 与 VoiceOver 使用。
- 已定义的标识符（勿随意改名，测试依赖它们）：
  - `sidebarToggleButton`、`editModeButton`、`titleLabel`、`statsLabel`、`pathControl`（TopToolbarView）
  - `sidebarOutline`、`sidebarFilterField`、`sidebarRowCell`、`sidebarHeader`（SidebarViewController）
  - `sourceEditor`、`sourceEditorScrollView`（SourceTextViewController）
  - `editorWebView`（WYSIWYGWebViewController）
  - `prefsTabControl`、`inspectCheck`、`styleTable`（PreferencesWindowController）
  - `webdavUrlField`、`webdavUsernameField`、`webdavPasswordField`、`webdavRemotePathField`、`webdavLocalPathField`、`webdavSelectFolderButton`、`webdavTestButton`、`webdavConfirmButton`、`webdavCancelButton`（WebDAVSetupDialog）
  - `placeholderTitle`、`placeholderMessage`（PlaceholderView）
  - `externalOpenButton`、`externalRevealButton`（ExternalOpenViewController）
  - `namePromptField`（NamePromptDialog）

### macOS XCUITest 元素匹配的坑（重要）
- NSTextField 的标签文本（`NSTextField(labelWithString:)`）暴露为 **`StaticText`**，其文本在 **`value`** 属性里，`label` 属性为空。断言文字内容请读 `.value`，不要读 `.label`。
- NSButton 的标题在 `label` 属性里。
- NSPathControl 暴露为 `StaticText`，`WKWebView` 的无障碍标识符会落在包裹它的 **`Group`** 上（真正的 `WebView` 是其子元素）。因此查询 WebView 时用 `app.descendants(matching: .any)["editorWebView"]` 或直接查 Group，而不是 `app.webViews[...]`。
- NSSegmentedControl 不是 iOS 的 `.segmentedControl`，用 `app.descendants(matching: .any)["prefsTabControl"]` 查询最稳。
