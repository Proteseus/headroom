import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Compact About block for Settings on Mac and iPhone: icon, name, version,
/// and who made it. Keeps the credit line in one place so the two surfaces
/// cannot drift.
struct AboutHeadroomView: View {
    var body: some View {
        VStack(spacing: 6) {
            appIcon
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            Text(HeadroomCopy.product)
                .font(.headline)

            Text(versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(HeadroomCopy.createdBy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(HeadroomCopy.publisher)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var versionLabel: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private var appIcon: Image {
        // AppIcon.appiconset is not loadable as a named image, and on an
        // LSUIElement menu-bar app `applicationIconImage` is the generic
        // "no icon" placeholder. AboutAppIcon is the same artwork kept for
        // in-app display on both Mac and iPhone.
        #if os(macOS)
        if let image = NSImage(named: "AboutAppIcon") {
            Image(nsImage: image)
        } else {
            Image(systemName: "app.fill")
        }
        #elseif os(iOS)
        if let image = UIImage(named: "AboutAppIcon") {
            Image(uiImage: image)
        } else {
            Image(systemName: "app.fill")
        }
        #else
        Image(systemName: "app.fill")
        #endif
    }
}
