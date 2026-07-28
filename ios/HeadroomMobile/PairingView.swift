import SwiftUI

struct PairingView: View {
    @ObservedObject var store: MobileUsageStore
    var isEditing = false

    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = MobileConnection.endpoint
    @State private var token = MobileTokenStore.read() ?? ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                TextField("Mac address", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Host token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Mac connection")
            } footer: {
                Text("Use your Mac’s .local hostname or LAN IP. The server runs on port 8737.")
            }

            Section("Find the token") {
                Text("On the Mac, run:")
                Text("cat ~/.headroom/token")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("The token never leaves your devices except in requests to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaving || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(isEditing ? "Connection" : "Connect to your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func save() async {
        guard let normalized = MobileConnection.normalize(endpoint) else {
            validationMessage = "Enter a valid Mac hostname or IP address."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try MobileTokenStore.save(
                token.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            UserDefaults.standard.set(normalized, forKey: MobileConnection.endpointKey)
            UserDefaults.standard.set(true, forKey: MobileConnection.configuredKey)
            validationMessage = nil
            await store.configured()
            if store.errorMessage == nil, isEditing {
                dismiss()
            } else if let error = store.errorMessage {
                validationMessage = error
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
