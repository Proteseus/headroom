import SwiftUI

/// The answers to an agent's request.
///
/// Two shapes, chosen by whether the answers carry their own reasons. Plain
/// answers — Allow once, Deny — are pills that wrap when three of them and a
/// long label will not fit a row. A question's options each come with the
/// reason you would pick them, so they become full-width rows with the reason
/// underneath: one control per option, instead of a list of descriptions
/// sitting above a row of buttons repeating the same words.
///
/// Tinted with the account's accent, so the answers belong to the agent that
/// asked rather than to the system.
struct FlowingActions: View {
    let actions: [AgentAttentionAction]
    let tint: Color
    let disabled: Bool
    let responding: Bool
    let answer: (AgentAttentionAction) -> Void

    private var isChoiceList: Bool {
        actions.contains { $0.subtitle?.isEmpty == false }
    }

    var body: some View {
        if isChoiceList {
            choiceList
        } else {
            ViewThatFits(in: .horizontal) {
                pillRow
                pillColumn
            }
        }
    }

    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(actions) { action in
                Button {
                    answer(action)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(color(for: action))
                        if let subtitle = action.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .tint(color(for: action))
                .disabled(disabled)
            }
            if responding { spinner }
        }
    }

    private var pillRow: some View {
        HStack(spacing: 8) {
            pills
            if responding { spinner }
            Spacer(minLength: 0)
        }
    }

    private var pillColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            pills
            if responding { spinner }
        }
    }

    @ViewBuilder
    private var pills: some View {
        ForEach(actions) { action in
            Button(action.label) { answer(action) }
                .buttonStyle(.bordered)
                .tint(color(for: action))
                .disabled(disabled)
        }
    }

    /// Deny is not destructive — it is the safe answer — so it keeps the
    /// accent. Only a genuinely destructive action earns an alarm colour, and
    /// **Ask on Mac** steps back because it is the one that answers nothing.
    private func color(for action: AgentAttentionAction) -> Color {
        if action.risk == "destructive" { return HeadroomPalette.red }
        if action.id == "ask_on_mac" { return HeadroomPalette.dim }
        return tint
    }

    private var spinner: some View {
        ProgressView().controlSize(.small)
    }
}
