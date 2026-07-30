import SwiftUI

/// Answer buttons that wrap instead of running off the edge.
///
/// A permission row can now carry three answers, and "Always allow this exact
/// request" is a long label by design — it is deliberately not Claude's
/// shorter "Yes, don't ask again", because Headroom saves a narrower rule and
/// the button should not claim otherwise. An `HStack` clipped it; this lays
/// the same buttons out in as many rows as they need.
struct FlowingActions: View {
    let actions: [AgentAttentionAction]
    let disabled: Bool
    let responding: Bool
    let answer: (AgentAttentionAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            column
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            buttons
            if responding { spinner }
            Spacer(minLength: 0)
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 6) {
            buttons
            if responding { spinner }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(actions) { action in
            Button(action.label) { answer(action) }
                .buttonStyle(.bordered)
                .disabled(disabled)
                // Deny is not destructive — it is the safe answer — so it
                // gets no alarm colour. Only a genuinely destructive action
                // earns one.
                .tint(action.risk == "destructive"
                      ? HeadroomPalette.red
                      : nil)
        }
    }

    private var spinner: some View {
        ProgressView().controlSize(.small)
    }
}
