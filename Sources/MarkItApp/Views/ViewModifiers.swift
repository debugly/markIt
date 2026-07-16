import SwiftUI

extension View {
    @ViewBuilder
    func clearScrollBackgroundIfAvailable() -> some View {
        #if compiler(>=5.7)
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
