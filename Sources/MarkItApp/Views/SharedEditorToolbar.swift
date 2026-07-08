import AppKit
import SwiftUI

struct SharedEditorToolbar: View {
    private static let trafficLightReservedWidth: CGFloat = 50
    private static let toolbarButtonSize: CGFloat = 24

    @ObservedObject var state: AppState

    private var document: DocumentModel {
        state.document
    }

    private var fileTitle: String {
        document.url?.lastPathComponent ?? "未命名"
    }

    private var statsText: String {
        let text = document.text
        let lines = max(text.split(whereSeparator: \.isNewline).count, text.isEmpty ? 0 : 1)
        let characters = document.plainText.characterCount
        return "\(lines) 行 · \(characters) 字"
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: Self.trafficLightReservedWidth)

            Button {
                state.showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: Self.toolbarButtonSize, height: Self.toolbarButtonSize)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("显示/隐藏目录")

            if let url = document.url {
                ToolbarPathControl(url: url)
                    .clipped()
            } else {
                Text(fileTitle)
                    .font(.system(size: 15, weight: .medium))
            }

            Spacer()

            Button {
                state.showEditor.toggle()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: Self.toolbarButtonSize, height: Self.toolbarButtonSize)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("显示/隐藏编辑器")

            if document.url != nil {
                Text(statsText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct ToolbarPathControl: NSViewRepresentable {
    let url: URL
    private let hiddenArrowWidth: CGFloat = 18

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.clipsToBounds = true

        let control = RightClickPathControl()
        control.pathStyle = .popUp
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 15, weight: .medium)
        control.focusRingType = .none
        control.isEditable = false
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.revealClickedPathItem(_:))
        control.url = url
        control.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(control)
        context.coordinator.pathControl = control

        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: hiddenArrowWidth),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.pathControl?.url = url
    }

    final class Coordinator: NSObject {
        weak var pathControl: NSPathControl?

        @objc func revealClickedPathItem(_ sender: NSPathControl) {
            let url = sender.clickedPathItem?.url ?? sender.url
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private final class RightClickPathControl: NSPathControl {
    override func mouseDown(with event: NSEvent) {
    }

    override func rightMouseDown(with event: NSEvent) {
        performClick(nil)
    }
}

extension String {
    var characterCount: Int {
        return self.filter { !$0.isWhitespace && !$0.isNewline }.count
    }
}
