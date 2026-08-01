import SwiftUI

/// Full-page empty state: a large ghost icon on the page background with a
/// short label under it. Not a list row — those read as a pill, and an empty
/// queue should feel open rather than contained.
struct PageEmptyState: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 76, weight: .ultraLight))
                .foregroundStyle(.quaternary)
                .symbolRenderingMode(.monochrome)
            Text(title)
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
