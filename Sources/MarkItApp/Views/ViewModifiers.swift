import SwiftUI

extension View {
    @ViewBuilder
    func clearScrollBackgroundIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
