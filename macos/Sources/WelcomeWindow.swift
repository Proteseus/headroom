import AppKit
import SwiftUI

/// First run, in a real window rather than in the popover.
///
/// The popover is `.transient` (see `StatusItemController`): a click anywhere
/// else tears it down mid-sentence, which is a bad place to put the one screen
/// a person reads exactly once. It also hangs off the very menu bar icon the
/// welcome has to point at, so it can't point at it. Hence a window.
extension Notification.Name {
    /// Settings asks for the welcome window; the app delegate owns it.
    static let headroomShowWelcome = Notification.Name("headroom.showWelcome")
}

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    /// Bumped when the panes change enough that returning users should see
    /// them again. `welcomeShownVersion` in defaults holds the last one shown,
    /// which is also what a future "What's new" pass would key off.
    static let currentVersion = 1
    static let shownVersionKey = "welcomeShownVersion"

    private var window: NSWindow?
    private var coachMark: CoachMarkWindow?
    private let store: UsageStore
    /// Where the menu bar icon is right now. A closure rather than a captured
    /// rect because the icon moves: another app claims a slot, the user drags
    /// it, a second display comes and goes.
    private let statusItemFrame: @MainActor () -> NSRect?
    private let onFinish: @MainActor () -> Void

    init(
        store: UsageStore,
        statusItemFrame: @escaping @MainActor () -> NSRect?,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.statusItemFrame = statusItemFrame
        self.onFinish = onFinish
        super.init()
    }

    /// True when this install has never shown the current welcome.
    static var isPending: Bool {
        UserDefaults.standard.integer(forKey: shownVersionKey) < currentVersion
    }

    static func markShown() {
        UserDefaults.standard.set(currentVersion, forKey: shownVersionKey)
    }

    func showIfPending() {
        guard Self.isPending else { return }
        show()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = WelcomeView(
            store: store,
            onPaneChange: { [weak self] pane in
                self?.updateCoachMark(for: pane)
            },
            onFinish: { [weak self] in
                self?.finish()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: WelcomeView.windowSize.width,
                    height: WelcomeView.windowSize.height)
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = HeadroomCopy.welcomeTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Liquid Glass and the vibrancy view behind it both sample what is
        // *behind the window*. Leave the window opaque with its default grey
        // and there is nothing to sample, so every panel renders as flat grey
        // and the whole thing looks like a form from 2014.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // An `.accessory` app can show a window but never gets a menu bar, so
        // Cmd-W and Cmd-Q do nothing and the window can't be reached from the
        // app switcher. Every menu bar app with an onboarding window does this
        // same flip; `windowWillClose` puts it back.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Finished by the button rather than by the close box. Same teardown, but
    /// this one opens the popover so the last pane's "it lives up there" lands
    /// on the thing itself.
    private func finish() {
        window?.close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        Self.markShown()
        coachMark?.hide()
        coachMark = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func updateCoachMark(for pane: WelcomePane) {
        guard pane == .find, let frame = statusItemFrame() else {
            coachMark?.hide()
            return
        }
        let mark = coachMark ?? CoachMarkWindow()
        coachMark = mark
        mark.show(under: frame)
    }
}

/// The arrow that points at the menu bar icon while the "find it" pane is up.
///
/// Borderless, click-through, and above the menu bar's own level so it isn't
/// clipped by it.
@MainActor
private final class CoachMarkWindow {
    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 86),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        window.contentView = NSHostingView(rootView: CoachMarkView())
    }

    func show(under iconFrame: NSRect) {
        let size = window.frame.size
        var origin = NSPoint(
            x: iconFrame.midX - size.width / 2,
            y: iconFrame.minY - size.height - 4
        )
        // Icons near the right edge would push the callout off screen.
        if let screen = NSScreen.screens.first(where: {
            $0.frame.intersects(iconFrame)
        }) {
            let maxX = screen.visibleFrame.maxX - size.width - 8
            origin.x = min(max(screen.visibleFrame.minX + 8, origin.x), maxX)
        }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// One solid callout: pointer and bubble in the same green, drawn as one piece.
///
/// It cannot be glass. Glass and the vibrancy view under it sample what is
/// behind the *window*, and this window is borderless, transparent and sitting
/// over whatever the desktop happens to be, so there was nothing to sample and
/// the tinted panel rendered as a near-black lozenge with the green nowhere in
/// it. A solid fill is also the only thing that stays legible over an arbitrary
/// wallpaper.
private struct CoachMarkView: View {
    /// Nudges the callout up and down so the eye catches it against whatever
    /// happens to be on screen behind the menu bar. The whole mark moves, so
    /// the pointer never separates from the bubble.
    @State private var bob = false

    var body: some View {
        VStack(spacing: 0) {
            CoachMarkPointer()
                .fill(HeadroomPalette.green)
                .frame(width: 18, height: 9)
            Text(HeadroomCopy.welcomeCoachMark)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                // Green at this luminance carries dark text about twice as well
                // as white: 6.4:1 against 3.3:1.
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Capsule().fill(HeadroomPalette.green))
                // Half a point of overlap, so the seam between the two fills
                // cannot show as a hairline on a fractional scale factor.
                .padding(.top, -0.5)
        }
        // One shadow for the assembled shape. Without the group each fill casts
        // its own, which draws a line where they meet.
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 9, y: 3)
        .offset(y: bob ? -3 : 1)
        .animation(
            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: bob)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { bob = true }
    }
}

/// The upward pointer. A plain triangle rather than `arrowtriangle.up.fill`,
/// whose glyph carries its own padding and left a gap above the bubble.
private struct CoachMarkPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
