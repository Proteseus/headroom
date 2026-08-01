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
            // Empty snapshot, healthy mark: three empty tanks so the slot is
            // never blank while the first poll is still out.
            button.image = MeterIconRenderer.render(
                snapshot: .empty,
                healthy: true,
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
            // Only off a healthy document: a failed poll replays the last good
            // one, and re-announcing a grant off a stale copy is how a reset
            // gets celebrated twice.
            if healthy {
                Task { await ResetNotifications.announce(snapshot) }
            }
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

    /// Where the icon sits on screen, for the welcome window's coach mark.
    /// Read on demand rather than cached: the icon moves when another app
    /// claims a slot, when it's dragged, and when a display comes or goes.
    var buttonScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window
        else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Open the dashboard from outside. The welcome window's last step uses
    /// this so "it lives up there" ends on the thing itself.
    func openPopover() {
        guard !popover.isShown else { return }
        togglePopover()
    }

    private func update(snapshot: UsageSnapshot, healthy: Bool) {
        let attention = snapshot.attention
        let showPip = attention?.isWarning == true
        statusItem.button?.image = MeterIconRenderer.render(
            snapshot: snapshot,
            healthy: healthy,
            attentionLevel: showPip ? attention?.level : nil
        )
        if !healthy {
            // "Backend" is not a word this product uses anywhere else, and
            // "unavailable" was doing four different jobs. Settings already
            // calls this thing the host.
            statusItem.button?.toolTip = "\(HeadroomCopy.product) — host not answering"
        } else if showPip, let attention {
            statusItem.button?.toolTip =
                "\(HeadroomCopy.product) — \(attention.summary ?? HeadroomCopy.needsAttention)"
        } else {
            let parts = snapshot.visibleQuotaProviders.map { provider in
                let meter = snapshot.meter(for: provider)
                guard let used = meter.menuBarWindow.percent else {
                    return "\(provider.displayTitle) —"
                }
                let remaining = 100 - used
                let pct = Int(max(0, min(remaining, 100)).rounded())
                return "\(provider.displayTitle) \(pct)% left"
            }
            statusItem.button?.toolTip = parts.isEmpty
                ? "Headroom"
                : "Headroom — \(parts.joined(separator: ", "))"
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
            // Settings subset only — never invent Claude/Codex/Cursor when
            // every quota source is off. The host picks which 3 (pinned
            // order, enabled only); icon geometry is sized for that same
            // hard limit. While the first poll is still out (or nothing is
            // enabled), draw that many empty tanks so the slot is never blank.
            let visibleProviders = snapshot.focusProviders()
            let barCount = visibleProviders.isEmpty ? 3 : visibleProviders.count
            let barWidthPixels = 6
            let barHeightPixels = 30
            let gapPixels = 5
            let groupWidth =
                barCount * barWidthPixels
                + max(0, barCount - 1) * gapPixels
            let groupX = (canvasPixels - groupWidth) / 2
            let barY = (canvasPixels - barHeightPixels) / 2

            // One vertical tank per provider. It shows the long quota window:
            // Weekly for Claude/Codex and Total for Cursor, which has no
            // weekly pool. The tank drains as consumption rises. With nothing
            // to show yet, draw three empty outlines so the slot is never blank.
            if visibleProviders.isEmpty {
                for index in 0..<barCount {
                    drawVerticalBar(
                        rect: PixelRect(
                            x: groupX + index * (barWidthPixels + gapPixels),
                            y: barY,
                            width: barWidthPixels,
                            height: barHeightPixels
                        ),
                        used: nil,
                        healthy: healthy
                    )
                }
            } else {
                for (index, provider) in visibleProviders.enumerated() {
                    let meter = snapshot.meter(for: provider)
                    drawVerticalBar(
                        rect: PixelRect(
                            x: groupX + index * (barWidthPixels + gapPixels),
                            y: barY,
                            width: barWidthPixels,
                            height: barHeightPixels
                        ),
                        used: meter.menuBarWindow.percent,
                        healthy: healthy,
                        unavailable: meter.menuBarWindow.percent == nil
                    )
                }
            }

            if warning {
                let pip = PixelRect(x: 26, y: 26, width: 8, height: 8)
                let color = HeadroomPalette.nsAttention(attentionLevel)
                color.setFill()
                NSBezierPath(ovalIn: pip.rect).fill()
            }
            return true
        }
        // Template icons can't show the colored warning pip.
        image.isTemplate = !warning
        let active = snapshot.visibleQuotaProviders
        if active.isEmpty {
            image.accessibilityDescription = "Headroom — no coding providers enabled"
        } else {
            let labels = active.map(\.displayTitle).joined(separator: ", ")
            image.accessibilityDescription = "\(labels) long-window quota remaining"
        }
        return image
    }

    private static func drawVerticalBar(
        rect pixelRect: PixelRect,
        used: Double?,
        healthy: Bool,
        unavailable: Bool = false
    ) {
        let base = NSColor.labelColor
        let alpha: CGFloat = unavailable ? 0.45 : 1
        let trackFillAlpha: CGFloat = healthy ? 0.28 : 0.18
        let trackStrokeAlpha: CGFloat = healthy ? 0.44 : 0.28
        let fillAlpha: CGFloat = healthy ? 1 : 0.55
        let frame = pixelRect.rect
        let radius = CGFloat(pixelRect.width / 2) / outputScale
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
            xRadius: CGFloat(max(0, pixelRect.width / 2 - insetPixels))
                / outputScale,
            yRadius: CGFloat(max(0, pixelRect.width / 2 - insetPixels))
                / outputScale
        )
        stroke.lineWidth = CGFloat(strokePixels) / outputScale
        base.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
        stroke.stroke()

        guard let used else { return }
        let remaining = 1 - max(0, min(used / 100, 1))
        let fillPixels = Int(
            (CGFloat(pixelRect.height) * CGFloat(remaining)).rounded()
        )
        guard fillPixels > 0 else { return }

        NSGraphicsContext.current?.cgContext.saveGState()
        track.addClip()
        base.withAlphaComponent(fillAlpha * alpha).setFill()
        NSBezierPath(
            rect: PixelRect(
                x: pixelRect.x,
                y: pixelRect.y,
                width: pixelRect.width,
                height: min(pixelRect.height, fillPixels)
            ).rect
        ).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
}
