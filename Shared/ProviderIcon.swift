import SwiftUI

/// One provider-id → mark contract for every Apple dashboard. Account ids keep
/// their base provider before `:`, so e.g. `codex:work` uses the Codex mark.
enum ProviderIcon {
    static func assetName(for id: String) -> String? {
        let providerID = String(id.split(separator: ":", maxSplits: 1).first ?? "")
        return switch providerID {
        case "claude": "ProviderClaude"
        case "codex": "ProviderCodex"
        case "cursor": "ProviderCursor"
        case "copilot": "ProviderCopilot"
        case "gemini": "ProviderGemini"
        case "windsurf": "ProviderWindsurf"
        case "jetbrains": "ProviderJetBrains"
        case "zed": "ProviderZed"
        default: nil
        }
    }
}

/// Monochrome by design: every SVG is an asset-catalog template and inherits
/// the surrounding primary/secondary foreground style on both macOS and iOS.
struct ProviderMark: View {
    let providerID: String
    var size: CGFloat

    var body: some View {
        if let assetName = ProviderIcon.assetName(for: providerID) {
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
