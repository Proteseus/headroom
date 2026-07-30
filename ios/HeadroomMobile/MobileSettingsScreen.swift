import SwiftUI

/// iOS Settings sheet — same destination taxonomy as Mac
/// (`SettingsDestination`). Reached from the gear in every tab's toolbar; it
/// owns the only navigation stack inside the sheet.
struct MobileSettingsScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Binding var showsConnection: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("backgroundRefreshEnabled") private var backgroundRefreshEnabled = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(SettingsDestination.iOSRoots, id: \.self) { dest in
                    NavigationLink(value: dest) {
                        Label(dest.title, systemImage: dest.symbol)
                    }
                }
            }
            .navigationTitle(HeadroomCopy.settings)
            .navigationDestination(for: SettingsDestination.self) { dest in
                pane(for: dest)
                    .navigationTitle(dest.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pane(for dest: SettingsDestination) -> some View {
        switch dest {
        case .connection:
            connectionPane
        case .sources:
            sourcesPane
        case .iPhone:
            iPhonePane
        case .about:
            aboutPane
        default:
            EmptyView()
        }
    }

    private var connectionPane: some View {
        Form {
            Section {
                if let name = store.snapshot.currentMachine?.name, !name.isEmpty {
                    LabeledContent("Mac", value: name)
                }
                LabeledContent("Address", value: connectionName)
                Button("Change connection", systemImage: "network") {
                    showsConnection = true
                }
            } footer: {
                Text(MobileConnection.endpoint)
            }
            // Four read-only rows do not need a screen of their own. They
            // belong next to the connection they qualify.
            Section {
                ForEach(MobilePermission.allCases, id: \.rawValue) { permission in
                    LabeledContent(permission.title) {
                        Label(
                            store.mobilePermissions[permission] ? "Allowed" : "Off",
                            systemImage: store.mobilePermissions[permission]
                                ? "checkmark.circle.fill"
                                : "minus.circle"
                        )
                        .foregroundStyle(
                            store.mobilePermissions[permission]
                                ? AnyShapeStyle(HeadroomPalette.green)
                                : AnyShapeStyle(.secondary)
                        )
                    }
                }
            } header: {
                Text(HeadroomCopy.settingsPermissions)
            } footer: {
                Text("Grants are set on the Mac under Settings → \(HeadroomCopy.settingsiPhone).")
            }
        }
    }

    private var sourcesPane: some View {
        Form {
            ForEach(groupedSources, id: \.group) { section in
                Section {
                    ForEach(section.sources) { source in
                        sourceRow(source)
                    }
                } header: {
                    Text(section.group.title)
                } footer: {
                    Text(footerText(for: section.group))
                }
            }
        }
    }

    /// Group subtitle, with the "where this list comes from" line tacked onto
    /// the last one. No refresh button down here: pull to refresh works on
    /// every tab and the status card already carries the icon.
    private func footerText(for group: SourceGroup) -> String {
        var parts = [group.subtitle]
        if group == .devtools {
            parts.append(
                "Add keys on the Mac under Settings → \(HeadroomCopy.settingsIntegrations)."
            )
        }
        if group == groupedSources.last?.group {
            parts.append(
                "Same list as Mac Settings → \(HeadroomCopy.settingsSources)."
            )
        }
        return parts.joined(separator: " ")
    }

    private var iPhonePane: some View {
        Form {
            Section {
                Toggle("Attention notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, enabled in
                        if enabled {
                            Task { await MobileNotifications.requestAuthorization() }
                        }
                    }
                Toggle("Background refresh", isOn: $backgroundRefreshEnabled)
            } footer: {
                // A fact, not a control. It sat between two toggles looking
                // like a third one.
                Text("Stopping a server from here asks for Face ID first.")
            }
        }
    }

    private var aboutPane: some View {
        Form {
            Section {
                AboutHeadroomView()
            }
        }
    }

    private var connectionName: String {
        MobileConnection.hostLabel
    }

    private var groupedSources: [(group: SourceGroup, sources: [SyncSource])] {
        (store.snapshot.sources ?? []).groupedBySourceGroup()
    }

    private func sourceRow(_ source: SyncSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title ?? source.id.capitalized)
                Text(sourceStatus(source))
                    .font(.caption)
                    .foregroundStyle(
                        source.ok == false
                            ? AnyShapeStyle(HeadroomPalette.amber)
                            : AnyShapeStyle(.secondary)
                    )
            }
            Spacer()
            if store.changingSourceID == source.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { source.enabled ?? true },
                        set: { enabled in
                            Task { await store.setSource(source.id, enabled: enabled) }
                        }
                    )
                )
                .labelsHidden()
                .disabled(!store.mobilePermissions.sources)
            }
        }
    }

    private func sourceStatus(_ source: SyncSource) -> String {
        if source.ok == false {
            return source.error ?? source.detail ?? "Error"
        }
        if let detail = source.detail ?? source.hint {
            return detail
        }
        return source.enabled == false ? "Off" : "OK"
    }
}
