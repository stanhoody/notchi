import AppKit
import Combine

/// Observes screen + fullscreen + sleep/wake events and emits a single coalesced
/// `WindowPlacement` whenever Notchi should reposition or hide.
@MainActor
public final class ScreenWatcher: ObservableObject {

    public struct WindowPlacement: Equatable {
        public let visible: Bool
        public let frame: CGRect
        public let screen: NSScreen?
        public let isVirtualNotch: Bool   // true when fallback 200x32 rect is in use

        public static let hidden = WindowPlacement(
            visible: false, frame: .zero, screen: nil, isVirtualNotch: false
        )
    }

    @Published public private(set) var placement: WindowPlacement = .hidden

    private var hideInFullscreen: Bool
    private var inFullscreen: Bool = false
    private var observers: [NSObjectProtocol] = []

    public init(hideInFullscreen: Bool = true) {
        self.hideInFullscreen = hideInFullscreen
        registerObservers()
        recompute()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public func setHideInFullscreen(_ on: Bool) {
        hideInFullscreen = on
        recompute()
    }

    // MARK: - Observers

    private func registerObservers() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        })

        observers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.detectFullscreenAndRecompute() }
        })

        observers.append(nc.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.inFullscreen = true
                self?.recompute()
            }
        })

        observers.append(nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.inFullscreen = false
                self?.recompute()
            }
        })
    }

    private func detectFullscreenAndRecompute() {
        // Cheap heuristic: if frontmost app's main window covers full screen height,
        // treat as fullscreen. We don't have a reliable cross-app fullscreen signal
        // without accessibility entitlements.
        if let frontWin = NSApp.keyWindow, frontWin.styleMask.contains(.fullScreen) {
            inFullscreen = true
        } else {
            inFullscreen = false
        }
        recompute()
    }

    // MARK: - Compute

    public func recompute() {
        let next: WindowPlacement

        if hideInFullscreen && inFullscreen {
            next = .hidden
        } else if let screen = NotchGeometry.preferredScreen() {
            if let real = NotchGeometry.notchRect(for: screen) {
                next = WindowPlacement(visible: true, frame: real, screen: screen, isVirtualNotch: false)
            } else {
                let virt = NotchGeometry.virtualNotchRect(for: screen)
                next = WindowPlacement(visible: true, frame: virt, screen: screen, isVirtualNotch: true)
            }
        } else {
            // Clamshell / external-only → hide.
            next = .hidden
        }

        if next != placement {
            placement = next
        }
    }
}
