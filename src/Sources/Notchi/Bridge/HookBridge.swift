import Darwin
import Foundation

/// Unix domain socket server that talks to Claude Code hook scripts.
///
/// Uses POSIX BSD sockets directly. Network.framework's `NWListener` does not
/// cleanly support `AF_UNIX` listeners (no port concept), so we stay close to the metal.
///
/// Protocol (newline-delimited JSON):
///   hook → app:  `{"id":..., "type":"session_start"|"session_stop"|"pre_tool_use", ...}`
///   app → hook:  `{"id":..., "type":"pre_tool_use_response", "decision":..., "reason":...}`
///
/// PreToolUse is BLOCKING — the hook reads the response on the same FD after writing
/// the request. HookBridge holds the FD until `sendResponse` is called.
public final class HookBridge: @unchecked Sendable {

    public static let primarySocketPath = "/tmp/notchi.sock"
    public static func fallbackSocketPath() -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.stanhoody.notchi/notchi.sock").path
    }

    /// True if a Notchi server is already accepting connections at `path`. Used as a
    /// single-instance guard so autostart + a manual launch don't fight over the socket
    /// (start() unlinks before binding, so a second instance would otherwise steal it).
    public static func isServerAlive(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        if bytes.count >= maxPath { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxPath) { c in
                for (i, b) in bytes.enumerated() { c[i] = CChar(bitPattern: b) }
                c[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        return r == 0
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case bindFailed(path: String, errno: Int32)
        case listenFailed(errno: Int32)
        case socketCreate(errno: Int32)
        public var description: String {
            switch self {
            case .bindFailed(let p, let e):   return "bind(\(p)) errno=\(e) (\(String(cString: strerror(e))))"
            case .listenFailed(let e):        return "listen errno=\(e)"
            case .socketCreate(let e):        return "socket() errno=\(e)"
            }
        }
    }

    private let socketPath: String
    private let engine: StateEngine
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.stanhoody.notchi.hook-accept")
    private let ioQueue = DispatchQueue(label: "com.stanhoody.notchi.hook-io",
                                         attributes: .concurrent)

    /// requestID → client FD held open until response is written
    private var pendingFDs: [String: Int32] = [:]
    private let pendingLock = NSLock()

    /// Gating is automatic: a tool is held (and Approve/Deny shown) only when Claude itself
    /// would prompt for it (see PermissionPolicy). `masterGate` is the user on/off switch and
    /// `islandVisible` lets us fall back to Claude's own prompt when the island can't be seen.
    private var _masterGate = true
    private var _islandVisible = true
    private let gateLock = NSLock()
    private let configDir = HookInstaller.defaultConfigDir()

    public func setMasterGate(_ on: Bool) { gateLock.lock(); _masterGate = on; gateLock.unlock() }
    public func setIslandVisible(_ v: Bool) { gateLock.lock(); _islandVisible = v; gateLock.unlock() }

    /// Whether to hold this specific tool and show Approve/Deny.
    private func shouldGate(_ p: PreToolUsePayload) -> Bool {
        gateLock.lock(); let master = _masterGate, visible = _islandVisible; gateLock.unlock()
        guard master, visible else { return false }
        return PermissionPolicy.shouldGate(toolName: p.toolName, toolInput: p.toolInput,
                                           cwd: p.cwd ?? "", configDir: configDir)
    }

    public init(engine: StateEngine, socketPath: String = HookBridge.primarySocketPath) {
        self.engine = engine
        self.socketPath = socketPath
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
    }

    // MARK: - Lifecycle

    public func start() throws {
        // Ensure parent directory exists (for fallback path inside Library/Caches).
        let dirURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Remove any stale socket file.
        unlink(socketPath)

        // socket()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw BridgeError.socketCreate(errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)    // don't leak the IPC socket into any future child
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)    // so acceptOne() can drain a burst to EAGAIN

        // Force the socket file to 0600 from the moment bind() creates it (no world-accessible
        // window between bind and chmod). Restored right after.
        let savedUmask = umask(0o177)
        defer { umask(savedUmask) }

        // bind()
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        precondition(pathBytes.count < maxPath, "socket path too long for sockaddr_un")
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxPath) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrLen)
            }
        }
        if bindResult != 0 {
            let e = errno
            close(fd)
            throw BridgeError.bindFailed(path: socketPath, errno: e)
        }

        // chmod 600 — only owner reads/writes.
        chmod(socketPath, 0o600)

        // listen()
        if Darwin.listen(fd, 16) != 0 {
            let e = errno
            close(fd)
            throw BridgeError.listenFailed(errno: e)
        }

        listenFD = fd
        installAcceptSource()
        installSignalHandlers()
        log("listener ready at \(socketPath)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func installAcceptSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler { [weak self] in
            guard let self = self, self.listenFD >= 0 else { return }
            close(self.listenFD)
            self.listenFD = -1
        }
        source.resume()
        self.acceptSource = source
    }

    private func acceptOne() {
        // Drain the whole backlog: with a non-blocking listen FD, loop until EAGAIN so a burst
        // of sessions firing in one tick can't leave a hook waiting.
        while true {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = Darwin.accept(listenFD, &clientAddr, &clientLen)
            if clientFD < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    log("accept failed errno=\(errno)")
                }
                return
            }
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            ioQueue.async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    // MARK: - Per-connection I/O

    private func handleConnection(fd: Int32) {
        var buffer = Data()
        let bufSize = 65_536
        let maxLine = 1_048_576   // drop a connection that floods >1MB without a newline
        var raw = [UInt8](repeating: 0, count: bufSize)
        var heldRequestID: String? = nil   // set when this connection is a held gate request

        while true {
            let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, bufSize)
            }
            if n <= 0 {
                // EOF or error. If we were holding a gate request and the hook gave up
                // (its `nc -w` timed out) or the response was consumed, clean up — no FD/dict leak.
                if let rid = heldRequestID {
                    pendingLock.lock()
                    let stillPending = pendingFDs.removeValue(forKey: rid) != nil
                    pendingLock.unlock()
                    // Only a NON-answered hold needs a revert. If sendResponse already fired,
                    // the entry was removed there, so stillPending is false and we skip it
                    // (the approve/deny already moved the session out of waitingPermission).
                    if stillPending {
                        let engineRef = engine
                        Task { await engineRef.apply(.permissionTimedOut(requestID: rid)) }
                    }
                }
                close(fd)               // single closer lives here, so sendResponse never closes
                return
            }
            buffer.append(raw, count: n)
            if buffer.count > maxLine && !buffer.contains(0x0A) {
                log("oversized line (\(buffer.count)B, no newline) — dropping connection")
                close(fd); return
            }

            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                guard let msg = HookLineDecoder.decode(line) else { continue }

                // One hook event per connection.
                if let rid = dispatch(msg, fd: fd) {
                    heldRequestID = rid     // gate hold — keep reading so EOF cleans us up
                    break                   // stop scanning lines; outer loop blocks on read for EOF/response
                } else {
                    close(fd)
                    return
                }
            }
        }
    }

    /// Translates a hook message into a semantic StateEngine event.
    /// Returns the held requestID if the FD is being HELD (PreToolUse in gate mode), else nil.
    private func dispatch(_ msg: HookMessage, fd: Int32) -> String? {
        let engineRef = engine
        switch msg {
        case .sessionStart(let p):
            log("event=SessionStart session=\(short(p.sessionID)) cwd=\(p.cwd)")
            Task { await engineRef.apply(.sessionStarted(sessionID: p.sessionID, cwd: p.cwd)) }
            return nil

        case .sessionEnd(let p):
            log("event=SessionEnd session=\(short(p.sessionID))")
            Task { await engineRef.apply(.sessionEnded(sessionID: p.sessionID)) }
            return nil

        case .stop(let p):
            log("event=Stop session=\(short(p.sessionID))")
            Task { await engineRef.apply(.stopped(sessionID: p.sessionID)) }
            return nil

        case .subagentStop(let p):
            log("event=SubagentStop session=\(short(p.sessionID))")
            Task { await engineRef.apply(.subAgentStopped(sessionID: p.sessionID)) }
            return nil

        case .postToolUse(let p):
            let err = p.isError
            log("event=PostToolUse session=\(short(p.sessionID)) tool=\(p.toolName) error=\(err)")
            Task { await engineRef.apply(.toolFinished(sessionID: p.sessionID, error: err)) }
            return nil

        case .notification(let p):
            log("event=Notification session=\(short(p.sessionID)) msg=\(p.message ?? "")")
            Task { await engineRef.apply(.attention(sessionID: p.sessionID, message: p.message)) }
            return nil

        case .preToolUse(let p):
            let tool = ToolKind.from(p.toolName)
            let gate = shouldGate(p)
            let sid = p.sessionID
            log("event=PreToolUse session=\(short(sid)) tool=\(p.toolName) gate=\(gate)")
            // Sarcastic reaction fires in both modes.
            if p.isSpicy {
                let line = Quips.danger()
                Task { await engineRef.apply(.quip(sessionID: sid, text: line)) }
            }
            if gate {
                let requestID = UUID().uuidString
                let req = PermissionRequest(
                    id: requestID, tool: tool, toolRawName: p.toolName,
                    preview: p.preview, description: p.descriptionText, timestamp: Date()
                )
                pendingLock.lock(); pendingFDs[requestID] = fd; pendingLock.unlock()
                log("gate HOLD req=\(short(requestID)) fd=\(fd) tool=\(p.toolName)")
                Task { await engineRef.apply(.permissionRequested(sessionID: sid, request: req)) }
                return requestID   // hold the FD; handleConnection cleans up on EOF
            } else {
                let cwd = p.cwd
                Task { await engineRef.apply(.toolStarted(sessionID: sid, cwd: cwd, tool: tool)) }
                if p.toolName == "Task" {
                    Task { await engineRef.apply(.subAgentStarted(sessionID: sid)) }
                }
                return nil
            }

        case .unknown(let rawType, _):
            log("unknown hook event: \(rawType)")
            return nil
        }
    }

    /// Called by the UI when Stan picks Approve/Deny (gate mode only). Writes the response line
    /// on the held FD. Does NOT close — the hook consumes the line and closes its side, and
    /// `handleConnection` (the single closer) reaps the FD on EOF. Safe to call from any thread.
    public func sendResponse(requestID: String, decision: PermissionDecision, reason: String? = nil) {
        pendingLock.lock()
        let fd = pendingFDs.removeValue(forKey: requestID)
        pendingLock.unlock()

        guard let fd = fd else {
            log("sendResponse: no held FD for requestID=\(requestID) (timed out or already answered)")
            return
        }
        log("sendResponse req=\(short(requestID)) decision=\(decision.rawValue)")
        let resp = PreToolUseResponse(decision: decision, reason: reason)
        guard var data = try? JSONEncoder().encode(resp) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { rawPtr in
            _ = Darwin.write(fd, rawPtr.baseAddress, rawPtr.count)
        }
        // No close here — handleConnection's read loop closes on EOF after the hook reads the line.
    }

    // MARK: - Signal handlers

    private func installSignalHandlers() {
        let cleanup: @convention(c) (Int32) -> Void = { _ in
            unlink(HookBridge.primarySocketPath)
            unlink(HookBridge.fallbackSocketPath())
            exit(0)
        }
        signal(SIGINT, cleanup)
        signal(SIGTERM, cleanup)
        signal(SIGHUP, cleanup)
    }

    // MARK: - Logging

    private func short(_ id: String) -> String { String(id.prefix(8)) }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[HookBridge] \(message)\n".utf8))
    }
}
