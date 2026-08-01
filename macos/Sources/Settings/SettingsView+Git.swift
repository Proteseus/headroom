import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var gitSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                (gitConfig.devRootExists
                    ? SettingsConnectionStatus(
                        "\(gitConfig.repos.count) repos found",
                        tone: .ok
                      )
                    : .folderMissing
                ).label()
            }
            if !gitEditable {
                Text("Git settings need a running, up to date host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Dev root",
                text: $gitDevRootDraft,
                prompt: Text("~/Dev")
            )
            TextField(
                "Commit authors",
                text: $gitAuthorsDraft,
                prompt: Text("you@example.com, Your Name (blank counts everyone)")
            )
            HStack {
                Button("Choose…") {
                    chooseDevRoot()
                }
                .disabled(!gitEditable)
                Button(HeadroomCopy.settingsSave) {
                    Task { await saveGitConfiguration() }
                }
                .disabled(savingGit || !gitEditable || gitDevRootDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if savingGit {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let gitMessage {
                Text(gitMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !gitConfig.repos.isEmpty {
                LabeledContent(HeadroomCopy.settingsScanning) {
                    Text(gitConfig.repos.prefix(12).joined(separator: ", ")
                         + (gitConfig.repos.count > 12 ? "…" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            // dev_root is out of SHARED_CONFIG_KEYS on purpose: it describes
            // one machine's disk. Authors are the same person everywhere, so
            // they do follow. Worth saying, because the two fields sit
            // together and behave differently.
            Text("Local commits under \(gitConfig.devRootPath.isEmpty ? gitConfig.devRoot : gitConfig.devRootPath) (including ones not pushed yet). No GitHub token — that is \(HeadroomCopy.githubActions). The folder stays on this Mac; commit authors follow you to your other Macs.")
        }
    }

    func reloadGitConfiguration() async {
        do {
            applyGitConfiguration(try await client.fetchGitConfiguration())
            gitEditable = true
        } catch {
            gitEditable = false
        }
    }

    func applyGitConfiguration(_ config: GitConfiguration) {
        gitConfig = config
        gitDevRootDraft = config.devRoot
        gitAuthorsDraft = config.authors.joined(separator: ", ")
    }

    func saveGitConfiguration() async {
        savingGit = true
        defer { savingGit = false }
        do {
            let config = try await client.setGitConfiguration(
                devRoot: gitDevRootDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                authors: splitList(gitAuthorsDraft)
            )
            applyGitConfiguration(config)
            gitMessage = config.repos.isEmpty
                ? "Saved. No repos under \(config.devRootPath) yet."
                : "Scanning \(config.repos.count) "
                    + (config.repos.count == 1 ? "repo." : "repos.")
            // GitHub discovers its repos under the same root, so a move that
            // only refreshed git would leave Actions watching the old one.
            await refreshSources(["git", "github"])
            await reloadGitHubWatch()
        } catch {
            gitMessage = error.localizedDescription
        }
    }

    /// A folder picker beside the field, because the most likely edit is
    /// "somewhere else on this disk" and typing a path is the worst way to say
    /// that. Mirrors `chooseCodexBinary()`.
    func chooseDevRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            gitDevRootDraft = url.path
            Task { await saveGitConfiguration() }
        }
    }
}
