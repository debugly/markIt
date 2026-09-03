//
//  NamePromptDialog.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Foundation

enum PromptContext {
    case newFolder(parent: URL)
    case newFile(parent: URL)
    case rename(target: URL)
    case duplicate(target: URL)

    var title: String {
        switch self {
        case .newFolder: return "新增文件夹"
        case .newFile: return "新增文件"
        case .rename: return "修改名称"
        case .duplicate: return "创建副本"
        }
    }

    var message: String {
        switch self {
        case .newFolder: return "请输入新的文件夹名称"
        case .newFile: return "请输入新的文件名称"
        case .rename: return "请输入新的名称"
        case .duplicate: return "请输入副本名称"
        }
    }

    var confirmLabel: String {
        switch self {
        case .newFolder, .newFile: return "创建"
        case .rename: return "保存"
        case .duplicate: return "创建"
        }
    }

    var initialValue: String {
        switch self {
        case .newFolder: return "新建文件夹"
        case .newFile: return "未命名.md"
        case .rename(let target): return target.lastPathComponent
        case .duplicate(let target):
            let ext = target.pathExtension
            let nameWithoutExt = target.deletingPathExtension().lastPathComponent
            return nameWithoutExt + " 副本" + (ext.isEmpty ? "" : ".\(ext)")
        }
    }
}

enum NamePromptDialog {
    static func show(
        context: PromptContext,
        on window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = context.title
        alert.informativeText = context.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: context.confirmLabel)
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = context.initialValue
        textField.isEditable = true
        textField.isSelectable = true
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        // If it's a file name, select just the name part without extension
        if let dotIndex = context.initialValue.lastIndex(of: ".") {
            let length = context.initialValue.distance(from: context.initialValue.startIndex, to: dotIndex)
            textField.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        } else {
            textField.selectText(nil)
        }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(trimmed.isEmpty ? nil : trimmed)
            } else {
                completion(nil)
            }
        }

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            let response = alert.runModal()
            handleResponse(response)
        }
    }
}
