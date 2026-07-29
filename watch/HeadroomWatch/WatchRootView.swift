import SwiftUI

/// The one screen behind both complications.
///
/// The phone already does detail; this exists so tapping a face lands
/// somewhere that answers the follow-up question — which source, how much,
/// and how old the numbers are. Full colour here, unlike the complications,
/// so the bands can wear the brand hues the rest of Headroom uses.
struct WatchRootView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        ScrollView {
            if let snapshot = link.snapshot, !snapshot.providers.isEmpty {
                content(snapshot)
            } else {
                empty
            }
        }
        .navigationTitle(HeadroomCopy.product)
    }

    @ViewBuilder
    private func content(_ snapshot: HeadroomWidgetSnapshot) -> some View {
        VStack(spacing: 12) {
            WatchRingsGlyph(providers: snapshot.providers, tinted: true)
                .frame(width: 110, height: 110)

            VStack(spacing: 6) {
                ForEach(snapshot.providers.sorted { $0.percent > $1.percent }) {
                    row($0)
                }
            }

            if !snapshot.charted.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HeadroomCopy.overallBurndown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WatchRundownChart(snapshot: snapshot)
                        .frame(height: 62)
                }
            }

            Text(
                snapshot.isStale
                    ? HeadroomCopy.recentHistory(age: snapshot.age)
                    : HeadroomCopy.ago(snapshot.age)
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func row(_ provider: HeadroomWidgetSnapshot.Provider) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(provider.tint)
                .frame(width: 7, height: 7)
            Text(provider.title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(HeadroomCopy.percentUsed(provider.percent))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            WatchRingsGlyph(providers: [], tinted: true)
                .frame(width: 88, height: 88)
                .opacity(0.5)
            Text(link.snapshot?.attentionSummary ?? HeadroomCopy.openOnPhone)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}
