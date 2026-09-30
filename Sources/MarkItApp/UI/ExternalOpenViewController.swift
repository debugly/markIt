//
//  ExternalOpenViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/4.
//

import AppKit

final class ExternalOpenViewController: NSViewController {
    private var targetURL: URL?

    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let tipLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let revealButton = NSButton()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 1. 文件大图标
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconImageView.widthAnchor.constraint(equalToConstant: 80),
            iconImageView.heightAnchor.constraint(equalToConstant: 80)
        ])

        // 2. 文件标题
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 2

        // 3. 文件大小和类型
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        // 4. 提示文字
        tipLabel.font = .systemFont(ofSize: 12, weight: .regular)
        tipLabel.textColor = .tertiaryLabelColor
        tipLabel.alignment = .center
        tipLabel.stringValue = "此文件类型不支持在内置编辑器中直接查看与编辑"

        // 5. 按钮区域
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 12

        // 主要打开按钮
        openButton.bezelStyle = .rounded
        openButton.focusRingType = .none
        openButton.target = self
        openButton.action = #selector(handleOpenExternal)
        openButton.keyEquivalent = "\r"
        openButton.bezelColor = .controlAccentColor
        openButton.setAccessibilityIdentifier("externalOpenButton")

        // 次要按钮：在访达中显示
        revealButton.bezelStyle = .rounded
        revealButton.focusRingType = .none
        revealButton.title = "在访达中显示"
        revealButton.target = self
        revealButton.action = #selector(handleRevealInFinder)
        revealButton.setAccessibilityIdentifier("externalRevealButton")

        buttonStack.addArrangedSubview(openButton)
        buttonStack.addArrangedSubview(revealButton)

        // 组装 Stack
        stack.addArrangedSubview(iconImageView)
        stack.setCustomSpacing(12, after: iconImageView)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.addArrangedSubview(tipLabel)
        stack.setCustomSpacing(20, after: tipLabel)
        stack.addArrangedSubview(buttonStack)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40)
        ])

        self.view = container
    }

    func configure(with url: URL) {
        self.targetURL = url

        // 图标
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 80, height: 80)
        iconImageView.image = icon

        // 标题
        titleLabel.stringValue = url.lastPathComponent

        // 副标题：文件大小与类型
        let sizeStr = SupportedFileType.formattedFileSize(for: url)
        let typeStr = SupportedFileType.localizedTypeDescription(for: url)
        if !sizeStr.isEmpty {
            subtitleLabel.stringValue = "\(typeStr) · \(sizeStr)"
        } else {
            subtitleLabel.stringValue = typeStr
        }

        // 默认应用识别
        let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        let appName: String
        if let defaultAppURL = defaultAppURL {
            let bundle = Bundle(url: defaultAppURL)
            appName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? defaultAppURL.deletingPathExtension().lastPathComponent
        } else {
            appName = "默认应用"
        }

        openButton.title = "使用 \(appName) 打开"
        if let defaultAppURL = defaultAppURL {
            let appIcon = NSWorkspace.shared.icon(forFile: defaultAppURL.path)
            appIcon.size = NSSize(width: 16, height: 16)
            openButton.image = appIcon
            openButton.imagePosition = .imageLeading
        } else {
            openButton.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            openButton.imagePosition = .imageLeading
        }
    }

    @objc private func handleOpenExternal() {
        guard let url = targetURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func handleRevealInFinder() {
        guard let url = targetURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
