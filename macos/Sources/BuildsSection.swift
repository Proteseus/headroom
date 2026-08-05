import AppKit
import SwiftUI

/// Active local Xcode / `xcodebuild` / `swift build` compiles. Row tap opens
/// the shared detail page; Reveal in Finder lives on that page.
struct BuildsSection: View {
    @ObservedObject var store: UsageStore
    @Binding var selection: ServiceDetailSelection?

    @AppStorage("serverRowLimit")
    private var rowLimit = 5

    var body: some View {
        let rows = Array((store.snapshot.local?.builds ?? [])
            .prefix(max(1, min(rowLimit, 8))))
        if !rows.isEmpty {
            DataSection(title: HeadroomCopy.xcodeBuilds) {
                ForEach(rows) { build in
                    row(build)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ build: LocalBuild) -> some View {
        Button {
            selection = .build(build.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(HeadroomPalette.green)
                    .frame(width: 7, height: 7)
                Text(build.name ?? "Xcode")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let action = build.action, action != "build" {
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let age = build.ageS {
                    Text(ageLabel(age))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ServiceDetailChevron()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show build detail")
    }

    private func ageLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return HeadroomCopy.agoShort(TimeInterval(seconds))
    }
}
