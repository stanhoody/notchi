import AppKit

/// Borderless, non-activating panel that lives above the menu bar at notch level.
/// Joins all spaces, survives fullscreen transitions (visible whenever menu bar is),
/// never steals focus.
public final class NotchWindow: NSPanel {

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Cosmetic: no titlebar, no minimize/zoom — borderless + nonactivating already gets us there.
        isMovable = false
        isReleasedWhenClosed = false
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
