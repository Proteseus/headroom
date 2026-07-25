import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var eventMonitor: Any?
    private var preferencesObserver: NSObjectProtocol?

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        super.init()

        if let button = statusItem.button {
            button.image = MeterIconRenderer.render(
                snapshot: .empty,
                healthy: false,
                attentionLevel: nil
            )
            button.imagePosition = .imageOnly
            button.toolTip = "Headroom"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(store: store)
        )

        store.onSnapshotChange = { [weak self] snapshot, healthy in
            self?.update(snapshot: snapshot, healthy: healthy)
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.update(
                    snapshot: self.store.snapshot,
                    healthy: self.store.errorMessage == nil
                )
            }
        }
    }

    private func update(snapshot: UsageSnapshot, healthy: Bool) {
        let attention = snapshot.attention
        if attention?.isWarning != true,
           AttentionAck.dismissedFingerprint != nil {
            AttentionAck.dismissedFingerprint = nil
        }
        let showPip = AttentionAck.shouldShowPip(for: attention)
        statusItem.button?.image = MeterIconRenderer.render(
            snapshot: snapshot,
            healthy: healthy,
            attentionLevel: showPip ? attention?.level : nil
        )
        if !healthy {
            statusItem.button?.toolTip = "Headroom — backend unavailable"
        } else if showPip, let attention {
            statusItem.button?.toolTip =
                "Headroom — \(attention.summary ?? "Needs attention")"
        } else {
            let parts = UsageProvider.allCases.map { provider in
                let meter = snapshot.meter(for: provider)
                let pct = Int((meter.headline.percent ?? 0).rounded())
                return "\(provider.title) \(pct)%"
            }
            statusItem.button?.toolTip = "Headroom — \(parts.joined(separator: ", "))"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Someone is looking — refresh now and hold the fast cadence.
            store.noteInteraction()
            Task { await store.refresh() }
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

enum MeterIconRenderer {
    private static let outputScale: CGFloat = 2
    private static let canvasPixels = 36

    private struct PixelRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var rect: CGRect {
            CGRect(
                x: CGFloat(x) / outputScale,
                y: CGFloat(y) / outputScale,
                width: CGFloat(width) / outputScale,
                height: CGFloat(height) / outputScale
            )
        }
    }

    static func render(
        snapshot: UsageSnapshot,
        healthy: Bool,
        attentionLevel: String? = nil
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let warning = attentionLevel == "warn" || attentionLevel == "critical"
        let image = NSImage(size: size, flipped: false) { _ in
            let providers = UsageProvider.allCases
            let barWidthPixels = 30
            let barHeightPixels = 6
            let gapPixels = 4
            let barX = (canvasPixels - barWidthPixels) / 2
            let stackHeight =
                providers.count * barHeightPixels
                + max(0, providers.count - 1) * gapPixels
            let stackY = (canvasPixels - stackHeight) / 2

            // Top → bottom matches overview left → right: Claude, Codex, Cursor.
            for (index, provider) in providers.enumerated() {
                let fromTop = index
                let y =
                    stackY
                    + (providers.count - 1 - fromTop)
                    * (barHeightPixels + gapPixels)
                let meter = snapshot.meter(for: provider)
                drawBar(
                    rect: PixelRect(
                        x: barX,
                        y: y,
                        width: barWidthPixels,
                        height: barHeightPixels
                    ),
                    remaining: meter.headline.percent.map { 100 - $0 },
                    healthy: healthy,
                    unavailable: meter.headline.percent == nil
                )
            }

            if warning {
                let pip = PixelRect(x: 26, y: 26, width: 8, height: 8)
                let color: NSColor = attentionLevel == "critical"
                    ? .systemRed : .systemOrange
                color.setFill()
                NSBezierPath(
                    ovalIn: pip.rect
                ).fill()
            }
            return true
        }
        // Template icons can't show the colored warning pip.
        image.isTemplate = !warning
        let labels = UsageProvider.allCases.map(\.title).joined(separator: ", ")
        image.accessibilityDescription = "\(labels) quota remaining"
        return image
    }

    private static func drawBar(
        rect pixelRect: PixelRect,
        remaining: Double?,
        healthy: Bool,
        unavailable: Bool = false
    ) {
        let base = NSColor.labelColor
        let alpha: CGFloat = unavailable ? 0.45 : 1
        let trackFillAlpha: CGFloat = healthy ? 0.28 : 0.18
        let trackStrokeAlpha: CGFloat = healthy ? 0.44 : 0.28
        let fillAlpha: CGFloat = healthy ? 1 : 0.55
        let frame = pixelRect.rect
        let radius = CGFloat(pixelRect.height / 2) / outputScale
        let track = NSBezierPath(
            roundedRect: frame,
            xRadius: radius,
            yRadius: radius
        )
        base.withAlphaComponent(trackFillAlpha * alpha).setFill()
        track.fill()

        let strokePixels = 2
        let insetPixels = strokePixels / 2
        let strokeRect = PixelRect(
            x: pixelRect.x + insetPixels,
            y: pixelRect.y + insetPixels,
            width: pixelRect.width - insetPixels * 2,
            height: pixelRect.height - insetPixels * 2
        )
        let stroke = NSBezierPath(
            roundedRect: strokeRect.rect,
            xRadius: CGFloat(max(0, pixelRect.height / 2 - insetPixels))
                / outputScale,
            yRadius: CGFloat(max(0, pixelRect.height / 2 - insetPixels))
                / outputScale
        )
        stroke.lineWidth = CGFloat(strokePixels) / outputScale
        base.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
        stroke.stroke()

        guard let remaining else { return }
        let clamped = max(0, min(remaining / 100, 1))
        let fillPixels = Int(
            (CGFloat(pixelRect.width) * CGFloat(clamped)).rounded()
        )
        guard fillPixels > 0 else { return }

        NSGraphicsContext.current?.cgContext.saveGState()
        track.addClip()
        base.withAlphaComponent(fillAlpha * alpha).setFill()
        NSBezierPath(
            rect: PixelRect(
                x: pixelRect.x,
                y: pixelRect.y,
                width: min(pixelRect.width, fillPixels),
                height: pixelRect.height
            ).rect
        ).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
}
