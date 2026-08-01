import SwiftUI

/// Past grants on one quota pool, newest first — when the pool came back and
/// how much it came back by.
///
/// A reset is the one event on a burndown card that happened *to* the budget
/// rather than being burned out of it, and on Codex it is usually something the
/// reader chose to spend a credit on. Naming each one to the minute is what
/// makes the sawtooth behind the live curve legible: every rise has a row.
///
/// Lives in `Shared/` because the Mac popover and the iPhone detail screen draw
/// the same list under the same chart. The widget and watch targets take an
/// explicit file list rather than the whole folder, so neither compiles it.
struct ResetHistoryList: View {
    let resets: [BurndownReset]
    let tint: Color
    /// Where the provider explains its own resets. Nil → plain header, no link.
    var noteURL: URL? = nil

    /// A card cannot absorb a fortnight of grants, and the host hands over as
    /// many as retention kept. Six covers the span the chart above actually
    /// draws; the rest are counted rather than dropped, because a list that
    /// silently ends reads as a list that is complete.
    private static let visibleLimit = 6

    private var ordered: [BurndownReset] {
        resets
            .filter { $0.t != nil }
            .sorted { ($0.t ?? 0) > ($1.t ?? 0) }
    }

    var body: some View {
        let visible = Array(ordered.prefix(Self.visibleLimit))
        let hidden = max(0, ordered.count - Self.visibleLimit)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HeadroomCopy.resetHistory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Codex resets are announced on the lead's account rather than
                // a status page — credit that source beside the list, not as
                // the section title itself.
                if let noteURL, let handle = Self.handle(from: noteURL) {
                    Link(handle, destination: noteURL)
                        .font(.caption.weight(.medium))
                }
            }

            ForEach(visible) { reset in
                HStack(spacing: 6) {
                    Circle()
                        .fill(tint.opacity(0.55))
                        .frame(width: 5, height: 5)
                    Text(
                        reset.date.map(HeadroomFormat.eventMoment)
                            ?? HeadroomCopy.resetGranted
                    )
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(HeadroomCopy.resetPointsBack(reset.forgivenPct))
                }
                .font(.caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }

            if hidden > 0 {
                Text("+\(hidden) earlier")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// `@handle` from an x.com / twitter.com profile URL. Anything else (a
    /// status page, a blog post) returns nil and the header stays plain.
    private static func handle(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host == "x.com" || host == "twitter.com" || host == "www.x.com"
                || host == "www.twitter.com"
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        return "@\(name)"
    }
}
