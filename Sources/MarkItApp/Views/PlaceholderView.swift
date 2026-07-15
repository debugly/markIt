import SwiftUI

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .medium))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title3)
                .foregroundColor(.primary)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
