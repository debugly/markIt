import SwiftUI

struct CompatMaterialView: View {
    var body: some View {
        if #available(macOS 12.0, *) {
            Color.clear.background(.regularMaterial)
        } else {
            Color.clear
        }
    }
}

struct CompatBarView: View {
    var body: some View {
        if #available(macOS 12.0, *) {
            Color.clear.background(.bar)
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }
}

extension View {
    @ViewBuilder
    func showUnsavedAlertCompat(isPresented: Binding<Bool>, onDecision: @escaping (UnsavedDecision) -> Void) -> some View {
        if #available(macOS 12.0, *) {
            self.alert("是否保存未命名的文件？", isPresented: isPresented) {
                Button("保存") { onDecision(.save) }
                Button("放弃", role: .destructive) { onDecision(.discard) }
                Button("取消", role: .cancel) { onDecision(.cancel) }
            } message: {
                Text("你的更改尚未保存。")
            }
        } else {
            self.background(
                AlertHelper(isPresented: isPresented, onDecision: onDecision)
            )
        }
    }

    @ViewBuilder
    func deleteConfirmationAlert(deleteTarget: Binding<URL?>, onConfirm: @escaping (URL) -> Void) -> some View {
        if #available(macOS 12.0, *) {
            self.alert("确认删除该文件？", isPresented: Binding(
                get: { deleteTarget.wrappedValue != nil },
                set: { if !$0 { deleteTarget.wrappedValue = nil } }
            )) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let target = deleteTarget.wrappedValue {
                        onConfirm(target)
                    }
                    deleteTarget.wrappedValue = nil
                }
            } message: {
                if let target = deleteTarget.wrappedValue {
                    Text(target.lastPathComponent)
                }
            }
        } else {
            self.alert(isPresented: Binding(
                get: { deleteTarget.wrappedValue != nil },
                set: { if !$0 { deleteTarget.wrappedValue = nil } }
            )) {
                Alert(
                    title: Text("确认删除该文件？"),
                    message: Text(deleteTarget.wrappedValue?.lastPathComponent ?? ""),
                    primaryButton: .destructive(Text("删除")) {
                        if let target = deleteTarget.wrappedValue {
                            onConfirm(target)
                        }
                        deleteTarget.wrappedValue = nil
                    },
                    secondaryButton: .cancel {
                        deleteTarget.wrappedValue = nil
                    }
                )
            }
        }
    }
}

private struct AlertHelper: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onDecision: (UnsavedDecision) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            DispatchQueue.main.async {
                isPresented = false
                let alert = NSAlert()
                alert.messageText = "是否保存未命名的文件？"
                alert.informativeText = "你的更改尚未保存。"
                alert.addButton(withTitle: "保存")
                alert.addButton(withTitle: "放弃")
                alert.addButton(withTitle: "取消")
                
                if let window = nsView.window {
                    alert.beginSheetModal(for: window) { response in
                        let decision: UnsavedDecision
                        switch response {
                        case .alertFirstButtonReturn: decision = .save
                        case .alertSecondButtonReturn: decision = .discard
                        default: decision = .cancel
                        }
                        onDecision(decision)
                    }
                } else {
                    let response = alert.runModal()
                    let decision: UnsavedDecision
                    switch response {
                    case .alertFirstButtonReturn: decision = .save
                    case .alertSecondButtonReturn: decision = .discard
                    default: decision = .cancel
                    }
                    onDecision(decision)
                }
            }
        }
    }
}
