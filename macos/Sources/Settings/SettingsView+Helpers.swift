import AppKit
import SwiftUI

/// Small pieces shared by several integration panes — no state of their own.
extension SettingsView {
    /// Both fields take a comma- or newline-separated list; the host does the
    /// real validation and says which entry it refused.
    func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Placeholder for a Keychain-backed SecureField: bullets when a token is
    /// already stored (so the row does not look empty), nothing otherwise.
    func keyFieldPrompt(stored: Bool) -> Text {
        Text(stored ? HeadroomCopy.settingsKeySavedPrompt : "")
    }

    /// Pasting a key means tracking the source. Enable (and un-dismiss) before
    /// refresh — otherwise `/sync/refresh` skips a Library/paused row and the
    /// phone keeps reading the blank "not connected" payload while Integrations
    /// already says Connected from Keychain alone.
    func connectAndRefresh(_ ids: [String]) async {
        do {
            _ = try await client.setSources(
                Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }))
        } catch {
            // Keychain already has the token; still try the refresh so a
            // permissions hiccup does not leave the save looking like a no-op.
        }
        await refreshSources(ids)
    }
}
