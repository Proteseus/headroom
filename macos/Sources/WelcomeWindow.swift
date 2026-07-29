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

private struct CoachMarkView: View {
    /// Nudges the arrow up and down so the eye catches it against whatever
    /// happens to be on screen behind the menu bar.
    @State private var bob = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 15))
                .foregroundStyle(HeadroomPalette.green)
                .offset(y: bob ? -3 : 1)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: bob)
            Text(HeadroomCopy.welcomeCoachMark)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .glassPanel(cornerRadius: 18, tint: HeadroomPalette.green)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { bob = true }
    }
}
