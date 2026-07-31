import SwiftUI

/// Give an agent a folder and a prompt.
///
/// The same control on both platforms, because starting work is the same act
/// on both. The Mac can add a folder with a picker; a phone cannot browse the
/// Mac's disk, so it chooses from the folders the Mac has already used —
/// which is why the host remembers them.
///
/// Only providers that can actually take work are offered. Claude is started
/// headless with `claude -p`, and its hooks report back exactly as they do for
/// a session you start in a terminal. Codex needs a thread of Headroom's own,
/// because a terminal session cannot reach Headroom's App Server.
struct StartAgentTaskView: View {
    let surface: AgentTaskSurface
    let tint: (String) -> Color
    var addFolder: (() -> Void)?
    var start: (String, String, String) async -> AgentTaskOutcome

    @State private var provider = ""
    @State private var folder = ""
    @State private var prompt = ""
    @State private var busy = false
    @State private var outcome: AgentTaskOutcome?

    private var providers: [AgentTaskProvider] { surface.startable }

    private var canStart: Bool {
        !busy && !provider.isEmpty && !folder.isEmpty
        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if providers.isEmpty {
            Text(HeadroomCopy.noAgentCanTakeWork)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(HeadroomCopy.startTaskAgent, selection: $provider) {
                ForEach(providers) { entry in
                    Text(entry.title).tag(entry.provider)
                }
            }
            .pickerStyle(.segmented)

            folderPicker

            TextField(
                HeadroomCopy.startTaskPromptPlaceholder,
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .onChange(of: prompt) { outcome = nil }

            HStack(spacing: 8) {
                Button(HeadroomCopy.startTask) {
                    Task {
                        busy = true
                        let result = await start(provider, folder, prompt)
                        outcome = result
                        // Only clear the prompt when the agent took it —
                        // otherwise the words you typed are gone and the
                        // failure is all you have left.
                        if result.ok { prompt = "" }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint(currentIconID))
                .disabled(!canStart)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let outcome {
                Label {
                    Text(outcome.message)
                } icon: {
                    Image(systemName: outcome.ok
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(outcome.ok
                                 ? HeadroomPalette.green
                                 : HeadroomPalette.red)
            }
        }
        .onAppear {
            if provider.isEmpty { provider = providers.first?.provider ?? "" }
            if folder.isEmpty { folder = surface.folders.first ?? "" }
        }
    }

    private var currentIconID: String {
        providers.first { $0.provider == provider }?.iconID ?? provider
    }

    @ViewBuilder
    private var folderPicker: some View {
        if surface.folders.isEmpty {
            // Nothing remembered yet, so there is nothing to choose between.
            // The Mac can fix that; a phone has to wait for it to.
            if addFolder != nil {
                Button(HeadroomCopy.chooseFolder) { addFolder?() }
                    .font(.subheadline)
            } else {
                Text(HeadroomCopy.noFoldersYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Picker(HeadroomCopy.startTaskFolder, selection: $folder) {
                    ForEach(surface.folders, id: \.self) { path in
                        Text(leaf(path)).tag(path)
                    }
                }
                .labelsHidden()
                if addFolder != nil {
                    Button(HeadroomCopy.chooseFolder) { addFolder?() }
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A full path is unreadable in a picker; the folder name is what you
    /// recognise. The whole path stays the value that is sent.
    private func leaf(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
