import SwiftUI

/// The subscription-price block under a provider's meters, one source for
/// both apps — the two copies it replaces had already been edited in step
/// only by luck. The surfaces differ in nothing but type scale, so that is
/// the whole parameter; the container (card, padding) stays with the caller.
struct SubscriptionPricingView: View {
    enum Scale {
        /// Mac popover: caption-sized, tight spacing.
        case compact
        /// Phone detail screen.
        case regular
    }

    let pricing: SubscriptionPricing
    let currentPlan: String?
    var scale: Scale = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: scale == .compact ? 7 : 8) {
            HStack {
                Text("Subscription price")
                    .font(scale == .compact ? .caption.weight(.medium) : .headline)
                Spacer()
                if let url = pricing.url.flatMap(URL.init(string:)) {
                    Link("Source", destination: url)
                        .font(scale == .compact ? .caption2 : .caption)
                }
            }
            if let price = pricing.currentPrice(for: currentPlan) {
                HStack(spacing: 8) {
                    // A matched price always has the id or title it matched
                    // on; the trailing fallback only satisfies the compiler.
                    Text(currentPlan ?? price.title ?? price.id ?? "")
                        .lineLimit(1)
                    Spacer()
                    Text(price.compactPrice)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(rowFont)
            } else if let currentPlan {
                HStack(spacing: 8) {
                    Text(currentPlan)
                        .lineLimit(1)
                    Spacer()
                    Text("See provider")
                        .foregroundStyle(.secondary)
                }
                .font(rowFont)
            } else {
                Text(HeadroomCopy.planUnknown)
                    .font(scale == .compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            if let checked = pricing.checked {
                Text("List prices · checked \(checked)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var rowFont: Font {
        scale == .compact ? .caption2 : .subheadline
    }
}
