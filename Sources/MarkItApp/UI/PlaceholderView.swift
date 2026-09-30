//
//  PlaceholderView.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit

final class PlaceholderView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

    init(title: String, systemImageName: String, message: String) {
        super.init(frame: .zero)
        setupUI(title: title, systemImageName: systemImageName, message: message)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI(title: "无打开的文件", systemImageName: "doc.text", message: "在左侧边栏选择或新建 Markdown 文件")
    }

    private func setupUI(title: String, systemImageName: String, message: String) {
        wantsLayer = true

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        messageLabel.stringValue = message
        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center

        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)

        titleLabel.setAccessibilityIdentifier("placeholderTitle")
        messageLabel.setAccessibilityIdentifier("placeholderMessage")

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    func update(title: String, systemImageName: String, message: String) {
        imageView.image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        titleLabel.stringValue = title
        messageLabel.stringValue = message
    }
}
