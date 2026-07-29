import SwiftUI

/// iOS Settings tab — same destination taxonomy as Mac (`SettingsDestination`).
struct MobileSettingsScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Binding var showsConnection: Bool
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
        }
    }

    @ViewBuilder
    private func pane(for dest: SettingsDestination) -> some View {
        switch dest {
        case .connection:
            connectionPane
        case .permissions:
            permissionsPane
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
                LabeledContent("Mac", value: connectionName)
                Button("Change connection", systemImage: "network") {
                    showsConnection = true
                }
            }
            Section {
                NavigationLink(value: SettingsDestination.permissions) {
                    Label(
                        HeadroomCopy.settingsPermissions,
                        systemImage: SettingsDestination.permissions.symbol
                    )
                }
            } footer: {
                Text("Grants are set on the Mac under Settings → \(HeadroomCopy.settingsiPhone).")
            }
        }
    }

    private var permissionsPane: some View {
        Form {
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
            } footer: {
                Text("Read-only here. Change them on the Mac.")
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
                    Text(section.group == .devtools
                         ? "\(section.group.subtitle) Add keys on the Mac under Settings → \(HeadroomCopy.settingsIntegrations)."
                         : section.group.subtitle)
                }
            }
            Section {
                Button(HeadroomCopy.refreshAll, systemImage: "arrow.clockwise") {
                    Task { await store.refresh(forceServerSync: true) }
                }
                .disabled(store.isLoading || !store.mobilePermissions.refresh)
            } footer: {
                Text("Same list as Mac Settings → \(HeadroomCopy.settingsSources).")
            }
        }
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
                LabeledContent("Server controls", value: "Face ID protected")
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
        URL(string: MobileConnection.endpoint)?.host() ?? MobileConnection.endpoint
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
