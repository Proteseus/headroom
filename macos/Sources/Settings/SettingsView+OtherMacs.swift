import SwiftUI

/// A sidebar root — see docs/multi-mac.md for the sync design.
extension SettingsView {
    var otherMacsPane: some View {
        Form {
            otherMacsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var otherMacsSection: some View {
            Section {
                Toggle(
                    "Share settings between my Macs",
                    isOn: Binding(
                        get: { multiMac.enabled },
                        set: { enabled in
                            multiMac.enabled = enabled
                            Task { await saveMultiMac(enabled) }
                        }
                    )
                )
                .disabled(endpointIsRemote || changingMultiMac)

                LabeledContent("This Mac") {
                    HStack(spacing: 6) {
                        Text(multiMac.machine.name)
                            .foregroundStyle(.secondary)
                        if changingMultiMac {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if multiMac.enabled {
                    // Ordered before the peer count on purpose: when macOS is
                    // blocking the read, "no other Macs yet" is not merely
                    // unhelpful, it is wrong. Publishing still works, so every
                    // Mac reports the same reassuring nothing.
                    if multiMac.mode == "cloudkit",
                       !MachineCloudSync.isAvailable {
                        // Only this side can know: the host has no idea how the
                        // app was signed. A development build silently doing
                        // nothing here is the most confusing outcome available.
                        //
                        // Two different reasons, and they need different
                        // answers. A notarized release with no iCloud profile
                        // is not something its owner can fix by downloading
                        // another copy of what they already have, which is
                        // exactly what the old wording sent them off to do.
                        Label(
                            MachineCloudSync.isDeveloperIDSigned
                            ? "This release was built without the iCloud "
                                + "profile, so multi-Mac sync is off."
                            : "Local builds cannot use iCloud. A notarized "
                                + "release carries the profile that turns "
                                + "multi-Mac sync on.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(HeadroomPalette.orange)
                    } else if let failure = MachineCloudSync.lastFailure {
                        // Ahead of the host's trouble_detail because that field
                        // only ever describes the folder transport. A CloudKit
                        // round that threw used to fall all the way through to
                        // "No other Macs yet", which reads as a working sync
                        // that nobody else has joined.
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.orange)
                    } else if let detail = multiMac.troubleDetail {
                        Label(detail, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.orange)
                    } else if multiMac.peers.isEmpty {
                        Text("No other Macs yet. Turn this on over there too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(multiMac.peers) { peer in
                            LabeledContent(peer.title) {
                                Text(peer.lastSeenLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Only in folder mode is there a path worth showing.
                    // CloudKit has nowhere for anyone to look.
                    if !multiMac.directory.isEmpty {
                        Text(multiMac.directory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let multiMacMessage {
                    Text(multiMacMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(endpointIsRemote
                     ? "Multi-Mac settings must be changed on the Mac running the Headroom host."
                     : "Enabled sources, provider order, and accent colours follow you between Macs over iCloud. Credentials, file paths, and this Mac's local servers and commits are never shared. Quota percentages already match everywhere, because your provider counts the account rather than the machine.")
            }
    }

    func reloadMultiMac() async {
        do {
            multiMac = try await client.fetchMultiMacConfiguration()
        } catch {
            multiMacMessage = error.localizedDescription
        }
    }

    func saveMultiMac(_ enabled: Bool) async {
        guard !changingMultiMac else { return }
        changingMultiMac = true
        multiMacMessage = nil
        defer { changingMultiMac = false }
        do {
            multiMac = try await client.setMultiMacConfiguration(enabled: enabled)
            if multiMac.enabled {
                multiMacMessage = multiMac.peers.isEmpty
                    ? nil
                    : "Found \(multiMac.peers.count) other Mac"
                        + (multiMac.peers.count == 1 ? "." : "s.")
            } else {
                // The folder is left where it is. Turning sync off should stop
                // this Mac publishing, not reach into iCloud and delete a
                // record the other Macs are still reading.
                multiMacMessage = "This Mac has stopped sharing."
            }
        } catch {
            multiMacMessage = error.localizedDescription
            await reloadMultiMac()
        }
    }
}
