import SwiftUI

struct MobileSettingsScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Binding var showsConnection: Bool
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("backgroundRefreshEnabled") private var backgroundRefreshEnabled = true

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Mac", value: connectionName)
                Button("Change connection", systemImage: "network") {
                    showsConnection = true
                }
            }

            Section("Permissions from Mac") {
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
                                ? Color.green
                                : Color.secondary
                        )
                    }
                }
            }

            ForEach(groupedSources, id: \.group) { section in
                Section {
                    ForEach(section.sources) { source in
                        sourceRow(source)
                    }
                } header: {
                    Text(section.group.title)
                } footer: {
                    Text(section.group == .devtools
                         ? "\(section.group.subtitle) Add keys on the Mac."
                         : section.group.subtitle)
                }
            }

            Section("iPhone") {
                Toggle("Attention notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, enabled in
                        if enabled {
                            Task { await MobileNotifications.requestAuthorization() }
                        }
                    }
                Toggle("Background refresh", isOn: $backgroundRefreshEnabled)
                LabeledContent("Server controls", value: "Face ID protected")
            }

            Section {
                Button(HeadroomCopy.refreshAll, systemImage: "arrow.clockwise") {
                    Task { await store.refresh(forceServerSync: true) }
                }
                .disabled(store.isLoading || !store.mobilePermissions.refresh)
            }
        }
        .navigationTitle(HeadroomCopy.settings)
    }

    private var connectionName: String {
        URL(string: MobileConnection.endpoint)?.host() ?? MobileConnection.endpoint
    }

    /// AI coding tools and dev tools answer different questions, so they get
    /// their own sections here the same way they do on the Mac.
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
                        source.ok == false ? Color.orange : Color.secondary
                    )
            }
            Spacer()
            if store.changingSourceID == source.id {
                ProgressView()
            } else {
                Toggle(
                    source.title ?? source.id,
                    isOn: Binding(
                        get: { source.enabled != false },
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
        if source.enabled == false { return "Off" }
        if let detail = source.detail { return detail }
        if let error = source.error { return error }
        if source.stale == true { return "Stale" }
        return source.ok == true ? "Healthy" : "Waiting"
    }
}
