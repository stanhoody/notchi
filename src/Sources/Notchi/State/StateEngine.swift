import Foundation

/// Actor that owns the per-session state map and applies semantic events from all sources
/// (the hook bridge, the JSONL watcher, user clicks, timers).
///
/// Single source of truth. Renderer subscribes via `snapshotStream`.
public actor StateEngine {

    public struct Snapshot: Sendable, Equatable {
        public let sessions: [SessionData]   // sorted: waitingPermission > working > idleWaiting, then lastActivity desc
        public let generatedAt: Date
    }

    private var sessions: [SessionID: SessionData] = [:]
    private var pendingPermissions: [String: PermissionRequest] = [:]   // requestID → request
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init() {}

    // MARK: - Snapshot stream

    public func snapshotStream() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
            continuation.yield(self.makeSnapshot())
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func makeSnapshot() -> Snapshot {
        let sorted = sessions.values.sorted { a, b in
            if a.state.sortPriority != b.state.sortPriority {
                return a.state.sortPriority > b.state.sortPriority
            }
            return a.lastActivity > b.lastActivity
        }
        return Snapshot(sessions: sorted, generatedAt: Date())
    }

    private func broadcast() {
        let snap = makeSnapshot()
        for cont in continuations.values { cont.yield(snap) }
    }

    // MARK: - Read accessors (mainly for tests)

    public func currentSessions() -> [SessionData] { makeSnapshot().sessions }
    public func state(for id: SessionID) -> SessionState? { sessions[id]?.state }
    public func session(for id: SessionID) -> SessionData? { sessions[id] }

    // MARK: - Apply events

    public func apply(_ event: NotchiEvent) {
        switch event {
        case .sessionStarted(let sid, let cwd):
            upsert(sid) { s in
                s.cwd = cwd.isEmpty ? s.cwd : cwd
                s.state = .idleWaiting
                s.needsAttention = false
                s.lastActivity = Date()
            } makeNew: {
                SessionData(id: sid, cwd: cwd, model: "", startedAt: Date(), state: .idleWaiting)
            }

        case .sessionEnded(let sid):
            if sessions.removeValue(forKey: sid) != nil { broadcast() }

        case .stopped(let sid):
            mutate(sid) { s in
                // Finished a turn after real work → a brief happy hop, then settle.
                let wasWorking: Bool = { if case .working = s.state { return true }; if case .thinking = s.state { return true }; return false }()
                s.state = wasWorking ? .celebrating : .idleWaiting
                s.needsAttention = false
                s.workingSince = nil
                s.subAgentCount = 0
                s.lastActivity = Date()
            }
            if case .celebrating? = sessions[sid]?.state {
                scheduleRevert(sid, from: .celebrating, to: .idleWaiting, after: 2.0)
            }

        case .toolStarted(let sid, let cwd, let tool):
            upsert(sid) { s in
                if let cwd, !cwd.isEmpty, s.cwd.isEmpty { s.cwd = cwd }
                let wasIdle: Bool = { if case .working = s.state { return false }; if case .thinking = s.state { return false }; return true }()
                if wasIdle || s.workingSince == nil { s.workingSince = Date() }
                s.state = .working(tool)
                s.needsAttention = false
                s.toolCount += 1
                s.lastActivity = Date()
            } makeNew: {
                var d = SessionData(id: sid, cwd: cwd ?? "", model: "", startedAt: Date(),
                                    state: .working(tool), toolCount: 1)
                d.workingSince = Date()
                return d
            }

        case .toolFinished(let sid, let error):
            mutate(sid) { s in
                if error {
                    s.state = .confused
                    s.quip = Quips.error(); s.quipUntil = Date().addingTimeInterval(3.0)
                } else if case .working = s.state {
                    s.state = .thinking            // composing the next step
                }
                s.lastActivity = Date()
            }
            if error, case .confused? = sessions[sid]?.state {
                scheduleRevert(sid, from: .confused, to: .thinking, after: 2.5)
                scheduleQuipClear(sid, after: 3.1)
            }

        case .permissionRequested(let sid, let request):
            pendingPermissions[request.id] = request
            upsert(sid) { s in
                s.state = .waitingPermission(request)
                s.needsAttention = true
                s.toolCount += 1
                s.lastActivity = Date()
            } makeNew: {
                SessionData(id: sid, cwd: "", model: "", startedAt: Date(),
                            state: .waitingPermission(request), needsAttention: true, toolCount: 1)
            }

        case .attention(let sid, let message):
            upsert(sid) { s in
                s.needsAttention = true
                s.attentionMessage = message
                s.lastActivity = Date()
            } makeNew: {
                SessionData(id: sid, cwd: "", model: "", startedAt: Date(),
                            state: .idleWaiting, needsAttention: true, attentionMessage: message)
            }

        case .quip(let sid, let text):
            mutate(sid) { s in s.quip = text; s.quipUntil = Date().addingTimeInterval(3.5) }
            scheduleQuipClear(sid, after: 3.6)

        case .subAgentStarted(let sid):
            mutate(sid) { s in s.subAgentCount += 1; s.lastActivity = Date() }

        case .subAgentStopped(let sid):
            mutate(sid) { s in s.subAgentCount = max(0, s.subAgentCount - 1) }

        case .userPermissionResponse(let reqID, let decision):
            applyUserPermission(requestID: reqID, decision: decision)

        case .permissionTimedOut(let reqID):
            // Hook gave up waiting (nc -w timeout / client closed). Treat like a non-answer:
            // drop the pending entry and revert the waving session to idle. No zombie.
            applyUserPermission(requestID: reqID, decision: .deny)

        case .sessionEvictionCheck:
            applyEvictionCheck()

        case .appWillSleep:
            break   // nothing to pause — TimelineViews idle on their own
        case .appDidWake:
            // After sleep, a session that was mid-tool may be stale; reconcile + drop the dead.
            applyEvictionCheck()
        }
    }

    // MARK: - Mutation helpers

    private func upsert(_ id: SessionID,
                        _ mutate: (inout SessionData) -> Void,
                        makeNew: () -> SessionData) {
        if var s = sessions[id] {
            mutate(&s)
            sessions[id] = s
        } else {
            sessions[id] = makeNew()
        }
        broadcast()
    }

    private func mutate(_ id: SessionID, _ body: (inout SessionData) -> Void) {
        guard var s = sessions[id] else { return }
        body(&s)
        sessions[id] = s
        broadcast()
    }

    private func applyUserPermission(requestID: String, decision: PermissionDecision) {
        guard let req = pendingPermissions.removeValue(forKey: requestID) else { return }
        for (sid, var sdata) in sessions {
            if case .waitingPermission(let pending) = sdata.state, pending.id == requestID {
                switch decision {
                case .approve: sdata.state = .working(req.tool)
                case .deny:    sdata.state = .idleWaiting
                }
                sdata.needsAttention = false
                sdata.lastActivity = Date()
                sessions[sid] = sdata
                break
            }
        }
        broadcast()
    }

    private func applyEvictionCheck() {
        let now = Date()
        let cutoff: TimeInterval = 30 * 60
        let permCutoff: TimeInterval = 60    // a gate nobody answered → revert (backstop to the EOF path)
        let stuckCutoff: TimeInterval = 5 * 60   // working/thinking with no events (sleep / crashed Claude) → idle
        var changed = false
        for (sid, sdata) in sessions {
            let idle = now.timeIntervalSince(sdata.lastActivity)
            switch sdata.state {
            case .idleWaiting where idle > cutoff:
                sessions.removeValue(forKey: sid)
                changed = true
            case .waitingPermission(let req) where idle > permCutoff:
                pendingPermissions.removeValue(forKey: req.id)
                var s = sdata; s.state = .idleWaiting; s.needsAttention = false
                sessions[sid] = s
                changed = true
            case .working, .thinking, .celebrating, .confused:
                if idle > stuckCutoff {
                    var s = sdata
                    s.state = .idleWaiting; s.workingSince = nil; s.subAgentCount = 0; s.needsAttention = false
                    sessions[sid] = s
                    changed = true
                }
            default:
                break
            }
        }
        if changed { broadcast() }
    }

    /// HookBridge calls this if it needs to drop a pending permission (e.g. connection died).
    public func consumePendingPermission(requestID: String) -> PermissionRequest? {
        pendingPermissions.removeValue(forKey: requestID)
    }

    // MARK: - Transient state auto-revert (celebrating, confused)

    private func scheduleRevert(_ sid: SessionID, from: SessionState, to: SessionState, after: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            self.revert(sid, from: from, to: to)
        }
    }

    private func revert(_ sid: SessionID, from: SessionState, to: SessionState) {
        guard var s = sessions[sid], s.state == from else { return }
        s.state = to
        sessions[sid] = s
        broadcast()
    }

    private func scheduleQuipClear(_ sid: SessionID, after: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            self.clearQuipIfExpired(sid)
        }
    }

    private func clearQuipIfExpired(_ sid: SessionID) {
        guard var s = sessions[sid], let until = s.quipUntil else { return }
        if Date() >= until {
            s.quip = nil; s.quipUntil = nil
            sessions[sid] = s
            broadcast()
        }
    }
}
