//
//  WebDAVSetupDialog.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit

final class WebDAVSetupDialog: NSWindowController {
    private let state: AppState

    private let urlField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let remotePathField = NSTextField()
    private let localPathField = NSTextField()
    private let selectFolderButton = NSButton()
    private let testButton = NSButton()
    private let testIndicator = NSProgressIndicator()
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()

    private var selectedLocalURL: URL?
    private let existingConfig: WebDAVFolderConfig?

    init(state: AppState, existingConfig: WebDAVFolderConfig? = nil, preselectedLocalURL: URL? = nil) {
        self.state = state
        self.existingConfig = existingConfig
        self.selectedLocalURL = preselectedLocalURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existingConfig == nil ? (preselectedLocalURL == nil ? "添加 WebDAV 同步文件夹" : "配置 WebDAV") : "编辑 WebDAV 设置"
        window.center()
        super.init(window: window)

        setupUI()
        populateExistingConfig()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func populateExistingConfig() {
        if let config = existingConfig {
            urlField.stringValue = config.serverURL.absoluteString
            usernameField.stringValue = config.username
            if let pwd = SyncCoordinator.shared.password(for: config.id) {
                passwordField.stringValue = pwd
            }
            remotePathField.stringValue = config.remotePath
            localPathField.stringValue = config.localPath
            if let resolved = config.resolveLocalURL() {
                selectedLocalURL = resolved
            } else {
                selectedLocalURL = URL(fileURLWithPath: config.localPath)
            }
        } else {
            if let local = selectedLocalURL {
                localPathField.stringValue = local.path
                recommendRemotePath(for: local)
            }
            if let latest = SyncCoordinator.shared.configs.last {
                urlField.stringValue = latest.serverURL.absoluteString
                usernameField.stringValue = latest.username
            }
        }
    }

    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.wantsLayer = true
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: existingConfig == nil ? "配置 WebDAV 同步" : "编辑 WebDAV 设置")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let hintLabel = NSTextField(labelWithString: "支持群晖 NAS、坚果云、Nextcloud 等。群晖请确保路径包含已有共享文件夹")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hintLabel)

        // Form Fields
        let urlLabel = makeLabel("服务器地址:")
        let userLabel = makeLabel("用户名:")
        let pwdLabel = makeLabel("密码 / 令牌:")
        let remoteLabel = makeLabel("云端目录:")
        let localLabel = makeLabel("本地文件夹:")

        urlField.placeholderString = "http://nas-ip:5005/"
        usernameField.placeholderString = "your-username"
        passwordField.placeholderString = "密码 / 令牌"
        remotePathField.placeholderString = "例如：/共享文件夹/MarkItNotes"
        localPathField.placeholderString = "请选择本地用于同步的文件夹"
        localPathField.isEditable = false

        urlField.setAccessibilityIdentifier("webdavUrlField")
        usernameField.setAccessibilityIdentifier("webdavUsernameField")
        passwordField.setAccessibilityIdentifier("webdavPasswordField")
        remotePathField.setAccessibilityIdentifier("webdavRemotePathField")
        localPathField.setAccessibilityIdentifier("webdavLocalPathField")

        selectFolderButton.title = "选择..."
        selectFolderButton.bezelStyle = .rounded
        selectFolderButton.focusRingType = .none
        selectFolderButton.target = self
        selectFolderButton.action = #selector(handleSelectFolder)
        selectFolderButton.setAccessibilityIdentifier("webdavSelectFolderButton")

        testButton.title = "测试连接"
        testButton.bezelStyle = .rounded
        testButton.focusRingType = .none
        testButton.target = self
        testButton.action = #selector(handleTestConnection)
        testButton.setAccessibilityIdentifier("webdavTestButton")

        testIndicator.style = .spinning
        testIndicator.controlSize = .small
        testIndicator.isDisplayedWhenStopped = false

        testStatusLabel.font = .systemFont(ofSize: 11)
        testStatusLabel.lineBreakMode = .byTruncatingTail

        confirmButton.title = existingConfig == nil ? "添加并同步" : "保存并同步"
        confirmButton.bezelStyle = .rounded
        confirmButton.focusRingType = .none
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.setAccessibilityIdentifier("webdavConfirmButton")

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.focusRingType = .none
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.setAccessibilityIdentifier("webdavCancelButton")

        let views = [
            titleLabel, hintLabel,
            urlLabel, urlField,
            userLabel, usernameField,
            pwdLabel, passwordField,
            remoteLabel, remotePathField,
            localLabel, localPathField, selectFolderButton,
            testButton, testIndicator, testStatusLabel,
            cancelButton, confirmButton
        ]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        // Layout constraints
        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            // Hint
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Server URL
            urlLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 20),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            urlLabel.widthAnchor.constraint(equalToConstant: 80),

            urlField.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),
            urlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Username
            userLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 14),
            userLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            userLabel.widthAnchor.constraint(equalToConstant: 80),

            usernameField.centerYAnchor.constraint(equalTo: userLabel.centerYAnchor),
            usernameField.leadingAnchor.constraint(equalTo: userLabel.trailingAnchor, constant: 8),
            usernameField.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),

            // Password
            pwdLabel.topAnchor.constraint(equalTo: userLabel.bottomAnchor, constant: 14),
            pwdLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            pwdLabel.widthAnchor.constraint(equalToConstant: 80),

            passwordField.centerYAnchor.constraint(equalTo: pwdLabel.centerYAnchor),
            passwordField.leadingAnchor.constraint(equalTo: pwdLabel.trailingAnchor, constant: 8),
            passwordField.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),

            // Remote Path
            remoteLabel.topAnchor.constraint(equalTo: pwdLabel.bottomAnchor, constant: 14),
            remoteLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            remoteLabel.widthAnchor.constraint(equalToConstant: 80),

            remotePathField.centerYAnchor.constraint(equalTo: remoteLabel.centerYAnchor),
            remotePathField.leadingAnchor.constraint(equalTo: remoteLabel.trailingAnchor, constant: 8),
            remotePathField.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),

            // Local Path
            localLabel.topAnchor.constraint(equalTo: remoteLabel.bottomAnchor, constant: 14),
            localLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            localLabel.widthAnchor.constraint(equalToConstant: 80),

            localPathField.centerYAnchor.constraint(equalTo: localLabel.centerYAnchor),
            localPathField.leadingAnchor.constraint(equalTo: localLabel.trailingAnchor, constant: 8),
            localPathField.trailingAnchor.constraint(equalTo: selectFolderButton.leadingAnchor, constant: -6),

            selectFolderButton.centerYAnchor.constraint(equalTo: localLabel.centerYAnchor),
            selectFolderButton.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),
            selectFolderButton.widthAnchor.constraint(equalToConstant: 70),

            // Test button & status
            testButton.topAnchor.constraint(equalTo: localLabel.bottomAnchor, constant: 20),
            testButton.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            testButton.widthAnchor.constraint(equalToConstant: 90),

            testIndicator.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            testIndicator.leadingAnchor.constraint(equalTo: testButton.trailingAnchor, constant: 8),

            testStatusLabel.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            testStatusLabel.leadingAnchor.constraint(equalTo: testIndicator.trailingAnchor, constant: 6),
            testStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Buttons bottom
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -12),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            confirmButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            confirmButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            confirmButton.widthAnchor.constraint(equalToConstant: 100)
        ])

    }

    private func recommendRemotePath(for localURL: URL) {
        let name = localURL.lastPathComponent
        if !name.isEmpty && name != "/" {
            remotePathField.stringValue = "/\(name)"
        }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .right
        return label
    }

    // MARK: - Actions

    @objc private func handleSelectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择同步文件夹"

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.selectedLocalURL = url
            self.localPathField.stringValue = url.path
        }
    }

    @objc private func handleTestConnection() {
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
              !usernameField.stringValue.isEmpty,
              !passwordField.stringValue.isEmpty else {
            testStatusLabel.textColor = .systemRed
            testStatusLabel.stringValue = "请先填写服务器地址、用户名和密码"
            return
        }

        testButton.isEnabled = false
        testIndicator.startAnimation(nil)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.stringValue = "正在连接..."

        let client = WebDAVClient(
            baseURL: url,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue
        )

        Task {
            do {
                print("[WebDAVSetupDialog] 开始测试连接: \(url.absoluteString)")
                _ = try await client.testConnection(remotePath: "")
                print("[WebDAVSetupDialog] 连接测试通过: \(url.absoluteString)")
                DispatchQueue.main.async {
                    self.testIndicator.stopAnimation(nil)
                    self.testButton.isEnabled = true
                    self.testStatusLabel.textColor = .systemGreen
                    self.testStatusLabel.stringValue = "✓ 连接验证成功"
                }
            } catch {
                print("[WebDAVSetupDialog Error] 连接测试失败: \(error.localizedDescription) (\(error))")
                DispatchQueue.main.async {
                    self.testIndicator.stopAnimation(nil)
                    self.testButton.isEnabled = true
                    self.testStatusLabel.textColor = .systemRed
                    self.testStatusLabel.stringValue = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func handleConfirm() {
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: urlString),
              !usernameField.stringValue.isEmpty,
              !passwordField.stringValue.isEmpty else {
            testStatusLabel.textColor = .systemRed
            testStatusLabel.stringValue = "请完整填写 WebDAV 配置"
            return
        }

        guard let localURL = selectedLocalURL else {
            testStatusLabel.textColor = .systemRed
            testStatusLabel.stringValue = "请指定本地文件夹"
            return
        }

        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        var remotePath = remotePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty else {
            testStatusLabel.textColor = .systemRed
            testStatusLabel.stringValue = "请指定云端目录路径"
            return
        }
        if !remotePath.hasPrefix("/") {
            remotePath = "/" + remotePath
        }

        // Ensure local directory exists
        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)

        // Create security bookmark for local URL
        let bookmarkData = try? localURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // 1. Immediately persist configuration so user edits are NEVER lost
        if let existing = self.existingConfig {
            var config = existing
            config.serverURL = serverURL
            config.username = username
            config.remotePath = remotePath
            config.localBookmark = bookmarkData ?? existing.localBookmark
            config.localPath = localURL.path
            SyncCoordinator.shared.updateConfig(config, password: password)
            self.state.addRootFolder(localURL, storeBookmark: true)
        } else {
            let config = WebDAVFolderConfig(
                serverURL: serverURL,
                username: username,
                remotePath: remotePath,
                localBookmark: bookmarkData,
                localPath: localURL.path
            )
            SyncCoordinator.shared.addConfig(config, password: password)
            self.state.addRootFolder(localURL, storeBookmark: true)
        }

        // 2. Indicate progress while creating remote directory
        confirmButton.isEnabled = false
        testButton.isEnabled = false
        testIndicator.startAnimation(nil)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.stringValue = "配置已保存，正在创建云端目录..."

        let client = WebDAVClient(
            baseURL: serverURL,
            username: username,
            password: password
        )

        Task {
            var creationError: Error?
            if !remotePath.isEmpty {
                do {
                    print("[WebDAVSetupDialog] 开始检查并创建云端目录: '\(remotePath)'")
                    try await client.ensureDirectoryHierarchy(remotePath: remotePath)
                    print("[WebDAVSetupDialog] 云端目录就绪: '\(remotePath)'")
                } catch {
                    print("[WebDAVSetupDialog Error] 云端目录创建失败 '\(remotePath)': \(error.localizedDescription) (\(error))")
                    creationError = error
                }
            }

            DispatchQueue.main.async {
                self.testIndicator.stopAnimation(nil)
                self.confirmButton.isEnabled = true
                self.testButton.isEnabled = true

                if let error = creationError {
                    self.testStatusLabel.textColor = .systemRed
                    let desc = error.localizedDescription
                    if desc.contains("403") || desc.contains("405") {
                        self.testStatusLabel.stringValue = "配置已保存。云端创建被拒(405/403): 群晖NAS请在控制面板创建共享文件夹，或填已有共享文件夹路径如 /共享文件夹/目录"
                    } else {
                        self.testStatusLabel.stringValue = "配置已保存。云端目录创建提示: \(desc)"
                    }
                } else {
                    self.window?.close()
                }
            }
        }
    }

    @objc private func handleCancel() {
        window?.close()
    }
}
