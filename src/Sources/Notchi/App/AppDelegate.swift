import AppKit
import Combine
import SwiftUI

/// Owns the lifecycle: NotchWindow, ScreenWatcher subscription, menu bar item.
/// SPM executable apps can't use `@main` + `@NSApplicationMain` directly, so the
/// `main.swift` entry point creates `NSApplication.shared`, installs this delegate,
/// and calls `app.run()`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let screenWatcher = ScreenWatcher()
    private let engine = StateEngine()
    private lazy var stateBridge = StateBridge(engine: engine)
    private let settings = SettingsStore()
    private var hookBridge: HookBridge?
    private var evictionTimer: Timer?
    private var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var settingsPopover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    // Arm-delay guard against a spurious tap landing as the permission UI appears.
    private var armedReqID: String?
    private var permissionArmedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)               // agent app, no Dock icon

        // Single-instance guard: if a Notchi is already serving the socket, bow out.
        let sockPath = ProcessInfo.processInfo.environment["NOTCHI_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
            ?? HookBridge.primarySocketPath
        if HookBridge.isServerAlive(at: sockPath) {
            log("another Notchi instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        installNotchWindow()
        installMenuBarItem()
        startHookBridge()
        refreshHooksOnLaunch()
        startEvictionTimer()
        wireIsland()
        wireSettings()
        hookBridge?.setMasterGate(settings.interceptPermissions)
        if ProcessInfo.processInfo.environment["NOTCHI_GATE"] == "0" {
            settings.interceptPermissions = false
        }
        log("Notchi v0.0.1 launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        evictionTimer?.invalidate()
        hookBridge?.stop()
        log("Notchi terminating")
    }

    /// M2-T8: poll StateEngine every 60s to evict sessions stale beyond 30min.
    private func startEvictionTimer() {
        evictionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [engine] _ in
            Task { await engine.apply(.sessionEvictionCheck) }
        }
    }

    private func startHookBridge() {
        let envSock = ProcessInfo.processInfo.environment["NOTCHI_SOCK"]
        let primaryPath = (envSock?.isEmpty == false) ? envSock! : HookBridge.primarySocketPath
        let bridge = HookBridge(engine: engine, socketPath: primaryPath)
        do {
            try bridge.start()
            hookBridge = bridge
        } catch {
            // Try fallback path inside ~/Library/Caches if /tmp is restricted.
            let fallback = HookBridge(engine: engine, socketPath: HookBridge.fallbackSocketPath())
            do {
                try fallback.start()
                hookBridge = fallback
                log("hook bridge using fallback socket path")
            } catch {
                log("hook bridge failed to start: \(error)")
            }
        }
    }

    // MARK: - Island interactions

    /// Tap on a character → toggle its details expansion + warm the token cache.
    private func handleSelect(_ sid: SessionID) {
        if stateBridge.expandedSessionID == sid {
            stateBridge.expandedSessionID = nil
            return
        }
        stateBridge.expandedSessionID = sid
        guard let session = stateBridge.sessions.first(where: { $0.id == sid }) else { return }
        // Avoid re-reading the transcript on rapid expand/collapse — read once per session.
        if stateBridge.tokensFor(session) != nil { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TokenStats.read(cwd: session.cwd, sessionID: session.id)
            DispatchQueue.main.async { [weak self] in self?.stateBridge.cacheTokens(stats, for: sid) }
        }
    }

    private func handleApprove(_ req: PermissionRequest) {
        guard armed(req) else { return }
        hookBridge?.sendResponse(requestID: req.id, decision: .approve)
        let e = engine
        Task { await e.apply(.userPermissionResponse(requestID: req.id, decision: .approve)) }
    }

    private func handleDeny(_ req: PermissionRequest) {
        guard armed(req) else { return }
        hookBridge?.sendResponse(requestID: req.id, decision: .deny, reason: "Denied in Notchi")
        let e = engine
        Task { await e.apply(.userPermissionResponse(requestID: req.id, decision: .deny)) }
    }

    private func armed(_ req: PermissionRequest) -> Bool {
        armedReqID == req.id && Date().timeIntervalSince(permissionArmedAt) > 0.4
    }

    /// Where Claude Code might be running, most-likely first. The Claude desktop app is the
    /// common case (JSONL entrypoint "claude-desktop"); terminals are the CLI fallback.
    private static let claudeBundleIDs: [String] = [
        "com.anthropic.claudefordesktop", "com.anthropic.claude",
    ]
    private static let terminalBundleIDs: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "co.zeit.hyper",
        "net.kovidgoyal.kitty", "com.microsoft.VSCode", "io.alacritty",
    ]

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) { app.activate() }
        else { app.activate(options: [.activateIgnoringOtherApps]) }
    }

    /// Focus the host of the tapped session. Resolves session_id → host process via
    /// ~/.claude/sessions/<PID>.json: a CLI session raises its exact terminal window; a
    /// desktop session activates Claude.app (the app exposes no per-tab handle, so that's the
    /// honest ceiling). Falls back to "activate any known host / launch Claude" if unresolved.
    private func focusTerminal(_ sid: SessionID) {
        defer { stateBridge.expandedSessionID = nil }

        // Forward-compat hook: the day Claude.app ships a session deep link, enable it here.
        // (Verified today: claude:// has no route to focus an existing session — see teardown.)

        if let rec = SessionLocator.find(sessionID: sid), rec.pid > 0 {
            if rec.isDesktop {
                if let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: Self.claudeBundleIDs[0]).first { activate(app); return }
            } else if let term = SessionLocator.ancestorApp(of: rec.pid, matching: Self.terminalBundleIDs) {
                activate(term); return   // real per-window focus for terminal-hosted sessions
            }
        }

        // Fallback: activate the first known host, else launch the Claude desktop app.
        let running = NSWorkspace.shared.runningApplications
        for bid in Self.claudeBundleIDs + Self.terminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == bid }) { activate(app); return }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeBundleIDs[0]) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Island sizing

    private func wireIsland() {
        Publishers.Merge3(
            stateBridge.$sessions.map { _ in () },
            stateBridge.$expandedSessionID.map { _ in () },
            screenWatcher.$placement.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateIsland() }
        .store(in: &cancellables)
        updateIsland()
    }

    /// Single source of truth for the island window frame + visibility.
    private var prevAttention: Set<SessionID> = []
    private var prevDone: Set<SessionID> = []

    private func playSoundsIfNeeded(_ sessions: [SessionData]) {
        guard settings.soundEnabled else { prevAttention = []; prevDone = []; return }
        let attn = Set(sessions.filter { $0.needsAttention }.map { $0.id })
        let done = Set(sessions.filter { if case .celebrating = $0.state { return true }; return false }.map { $0.id })
        if !attn.subtracting(prevAttention).isEmpty { NotchiSound.play(NotchiSound.needsYou) }
        if !done.subtracting(prevDone).isEmpty { NotchiSound.play(NotchiSound.done) }
        prevAttention = attn
        prevDone = done
    }

    private func updateIsland() {
        guard let window = notchWindow else { return }
        playSoundsIfNeeded(stateBridge.sessions)
        let placement = screenWatcher.placement
        hookBridge?.setIslandVisible(placement.visible)
        guard placement.visible else { window.orderOut(nil); return }

        let notch = placement.frame
        if stateBridge.notchHeight != notch.height { stateBridge.notchHeight = notch.height }

        let sessions = stateBridge.sessions
        let expansion = IslandLayout.expansion(sessions: sessions, clicked: stateBridge.expandedSessionID)

        if case .permission(_, let req) = expansion, req.id != armedReqID {
            armedReqID = req.id
            permissionArmedAt = Date()
        }

        guard IslandLayout.isVisible(sessionCount: sessions.count, expansion: expansion) else {
            window.orderOut(nil); return
        }

        let hasSub = sessions.prefix(6).contains { $0.subAgentCount > 0 }
        let size = IslandLayout.windowSize(notchWidth: notch.width, notchHeight: notch.height,
                                           sessionCount: sessions.count, expansion: expansion,
                                           hasSubAgents: hasSub)
        let frame = CGRect(x: notch.midX - size.width / 2,
                           y: notch.maxY - size.height,        // top flush with the screen edge
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    // MARK: - Settings hot-reload

    private func wireSettings() {
        settings.$opacity
            .receive(on: RunLoop.main)
            .sink { [weak self] v in self?.notchWindow?.alphaValue = CGFloat(v) }
            .store(in: &cancellables)

        settings.$hideInFullscreen
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.screenWatcher.setHideInFullscreen(on) }
            .store(in: &cancellables)

        settings.$interceptPermissions
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                self.hookBridge?.setMasterGate(on)
                self.updateIsland()
                self.refreshSettingsPopover()
            }
            .store(in: &cancellables)
    }

    /// The JSONL watcher is NOT started: its sink is a no-op (hooks are the sole state driver),
    /// and starting it opens a DispatchSource per project + per transcript file — dozens of FDs
    /// doing real work for nothing. Phase 4 will start it only once it has a real sink.
    /// Instead, on launch we refresh the installed hook scripts so script fixes (e.g. the
    /// `nc -w 30` timeout) land without the user manually reinstalling.
    private func refreshHooksOnLaunch() {
        let status = HookInstaller.status()
        guard status.scriptsPresent else { return }
        do { try HookInstaller.install(); log("hook scripts refreshed on launch") }
        catch { log("hook refresh failed: \(error)") }
    }

    // MARK: - Notch window

    private func installNotchWindow() {
        let window = NotchWindow()
        let notchWidth = screenWatcher.placement.frame.width > 0 ? screenWatcher.placement.frame.width : 185
        // FirstMouseHostingView so a click lands on the SwiftUI button even though the panel is
        // a non-key, nonactivating panel of an .accessory app (otherwise AppKit drops the
        // first-mouse click and buttons appear dead).
        let host = FirstMouseHostingView(rootView: IslandView(
            model: self.stateBridge,
            settings: self.settings,
            notchWidth: notchWidth,
            onSelect: { [weak self] sid in self?.handleSelect(sid) },
            onApprove: { [weak self] req in self?.handleApprove(req) },
            onDeny: { [weak self] req in self?.handleDeny(req) },
            onFocusTerminal: { [weak self] sid in self?.focusTerminal(sid) }
        ))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        notchWindow = window
        // Frame + visibility are driven by updateIsland().
    }

    // MARK: - Menu bar item

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "face.smiling.inverse",
                                 accessibilityDescription: "Notchi") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "◖◗"
            }
            button.toolTip = "Notchi — Claude Code companion"
            button.target = self
            button.action = #selector(toggleSettingsPopover)
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = settingsPopoverSize()
        popover.contentViewController = NSHostingController(rootView: settingsView())
        settingsPopover = popover
    }

    /// Fixed popover size — the SwiftUI content scrolls inside it, so a tall settings list never
    /// runs off the top of the screen.
    private func settingsPopoverSize() -> NSSize {
        let avail = (NSScreen.main?.visibleFrame.height ?? 700) - 24
        return NSSize(width: 280, height: min(560, avail))
    }

    private func settingsView() -> SettingsView {
        let status = HookInstaller.status()
        return SettingsView(
            settings: settings,
            hooksInstalled: status.scriptsPresent && status.settingsRegistered,
            onInstallHooks: { [weak self] in self?.installHooks() },
            onUninstallHooks: { [weak self] in self?.uninstallHooks() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func refreshSettingsPopover() {
        settingsPopover?.contentSize = settingsPopoverSize()
        settingsPopover?.contentViewController = NSHostingController(rootView: settingsView())
    }

    @objc private func toggleSettingsPopover() {
        guard let button = statusItem?.button, let popover = settingsPopover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshSettingsPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func installHooks() {
        do { try HookInstaller.install(); log("hooks installed") }
        catch { log("hooks install failed: \(error)") }
        refreshSettingsPopover()
    }

    private func uninstallHooks() {
        do { try HookInstaller.uninstall(); log("hooks uninstalled") }
        catch { log("hooks uninstall failed: \(error)") }
        refreshSettingsPopover()
    }

    // MARK: - Logging

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Notchi] \(message)\n".utf8))
    }
}
