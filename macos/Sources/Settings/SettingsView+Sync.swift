import SwiftUI

extension SettingsView {
    /// One place for the devices that can join Headroom: the iPhone companion
    /// and the other Macs that share this Mac's settings.
    var syncPane: some View {
        Form {
            iPhoneSection
            otherMacsSection
        }
        .formStyle(.grouped)
    }
}
