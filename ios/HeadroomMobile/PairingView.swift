import SwiftUI
import UIKit

struct PairingView: View {
    @ObservedObject var store: MobileUsageStore
    var isEditing = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BonjourDiscovery()
    @State private var endpoint = MobileConnection.endpoint
    @State private var token = MobileTokenStore.read() ?? ""
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var tokenCommandCopied = false
    @State private var tokenPasted = false

    var body: some View {
        Form {
            Section {
                if discovery.services.isEmpty {
                    HStack(spacing: 12) {
                        if discovery.isSearching {
                            ProgressView()
                            Text(HeadroomCopy.searchingNearby)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                            Text(discovery.errorMessage ?? "No Headroom Macs found.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Search again") {
                        discovery.restart()
                    }
                    .disabled(discovery.isSearching)
                } else {
                    ForEach(discovery.services) { mac in
                        Button {
                            endpoint = mac.endpoint
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")
                                Spacer()
                                if endpoint == mac.endpoint {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                Text("Mac running + Local Network on.")
            }

            Section {
                TextField("Mac address", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack {
                    SecureField("Mobile token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(tokenPasted ? "Pasted" : "Paste") {
                        pasteToken()
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSaving)
                }
            } header: {
                Text("Mac connection")
            } footer: {
                Text("Or enter a Tailscale / LAN address.")
            }

            Section("Find the mobile token") {
                Text("On the Mac: Settings → iPhone pairing → Copy mobile token. Or run:")
                HStack {
                    Text("cat ~/.headroom/mobile-token")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(tokenCommandCopied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = "cat ~/.headroom/mobile-token"
                        tokenCommandCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            tokenCommandCopied = false
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Text("Use the mobile token only — not ~/.headroom/token (that’s the host token for the ESP32). It never leaves your devices except in requests to your Mac.")
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
        .onAppear {
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
        }
        .onChange(of: discovery.services) { _, services in
            if services.count == 1,
               endpoint == MobileConnection.defaultEndpoint {
                endpoint = services[0].endpoint
            }
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Generated host tokens are `secrets.token_urlsafe(32)` → 43 chars.
    private static let expectedTokenLength = 43

    private func pasteToken() {
        guard let pasted = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !pasted.isEmpty
        else { return }
        token = pasted
        tokenPasted = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            tokenPasted = false
        }
        if pasted.count == Self.expectedTokenLength,
           MobileConnection.normalize(endpoint) != nil {
            Task { await save() }
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
