import SwiftUI

/// The island: a single black shape that extends the physical notch. Characters live in the
/// top band beside the camera; a request expands the island downward and renders its UI inside
/// the same black shape (Dynamic-Island style — no separate floating modal).
struct IslandView: View {
    @ObservedObject var model: StateBridge
    @ObservedObject var settings: SettingsStore
    var onSelect: (SessionID) -> Void = { _ in }
    var onApprove: (PermissionRequest) -> Void = { _ in }
    var onDeny: (PermissionRequest) -> Void = { _ in }
    var onFocusTerminal: (SessionID) -> Void = { _ in }

    @State private var tokenMode: TokenMode = .session
    enum TokenMode: CaseIterable { case session, today, fiveHour
        var label: String { switch self { case .session: return "Session"; case .today: return "Today"; case .fiveHour: return "5h" } }
    }

    private let notchWidth: CGFloat
    init(model: StateBridge, settings: SettingsStore, notchWidth: CGFloat,
         onSelect: @escaping (SessionID) -> Void = { _ in },
         onApprove: @escaping (PermissionRequest) -> Void = { _ in },
         onDeny: @escaping (PermissionRequest) -> Void = { _ in },
         onFocusTerminal: @escaping (SessionID) -> Void = { _ in }) {
        self.model = model
        self.settings = settings
        self.notchWidth = notchWidth
        self.onSelect = onSelect
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onFocusTerminal = onFocusTerminal
    }

    var body: some View {
        let sessions = visible(model.sessions)
        let expansion = IslandLayout.expansion(sessions: model.sessions, clicked: model.expandedSessionID)
        let hasSub = sessions.contains { $0.subAgentCount > 0 }
        let band = IslandLayout.bandHeight(notchHeight: model.notchHeight, hasSubAgents: hasSub)
        let parentY = IslandLayout.parentCenterY(notchHeight: model.notchHeight)

        GeometryReader { geo in
            let W = geo.size.width
            let pts = IslandLayout.charPositions(windowWidth: W, notchWidth: notchWidth,
                                                 centerY: parentY, count: sessions.count)
            ZStack(alignment: .top) {
                // Black island shape — extends the notch. Square top, rounded bottom.
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                                       bottomTrailingRadius: 14, topTrailingRadius: 0,
                                       style: .continuous)
                    .fill(Color.black)

                ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                    let p = pts.indices.contains(idx) ? pts[idx] : CGPoint(x: W / 2, y: parentY)
                    parentCharacter(session)
                        .position(p)
                    speechBubble(session)
                        .position(x: p.x, y: Swift.max(6, p.y - IslandLayout.charHeight / 2 - 2))
                    subAgents(session, at: p, childY: childRowY())
                }

                if expansion.isExpanded {
                    VStack(spacing: 0) {
                        Spacer().frame(height: band)
                        expansionContent(expansion)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func childRowY() -> CGFloat { Swift.max(model.notchHeight, 30) + 9 }

    private func visible(_ sessions: [SessionData]) -> [SessionData] {
        Array(sessions.prefix(6))
    }

    private func parentCharacter(_ session: SessionData) -> some View {
        SpriteView(state: session.state,
                   needsAttention: session.needsAttention,
                   lastActivity: session.lastActivity,
                   workingSince: session.workingSince,
                   skin: settings.skin(for: session.id),
                   pixel: IslandLayout.bandPixel,
                   speed: settings.speed,
                   accentColor: settings.creatureColor)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(session.id) }
    }

    /// Sub-agent companions (Task tool) — up to 2 mini creatures below the parent, then +N.
    @ViewBuilder
    private func subAgents(_ session: SessionData, at p: CGPoint, childY: CGFloat) -> some View {
        let n = session.subAgentCount
        if n > 0 {
            let shown = Swift.min(n, 2)
            let mini = IslandLayout.bandPixel * 0.62
            let slot: CGFloat = 22 * mini + 3
            ForEach(0..<shown, id: \.self) { j in
                let dx = (CGFloat(j) - CGFloat(shown - 1) / 2) * slot
                SpriteView(state: .working(.bash), skin: settings.skin(for: session.id), pixel: mini,
                           speed: settings.speed, accentColor: settings.creatureColor)
                    .position(x: p.x + dx, y: childY)
            }
            if n > shown {
                Text("+\(n - shown)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .position(x: p.x + slot, y: childY)
            }
        }
    }

    /// A tiny speech bubble for quick at-a-glance status (done / needs you / error).
    @ViewBuilder
    private func speechBubble(_ session: SessionData) -> some View {
        if let text = bubbleText(session) {
            Text(text)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(bubbleColor(session)))
                .fixedSize()
        }
    }

    private func bubbleText(_ s: SessionData) -> String? {
        if let q = s.quip, let until = s.quipUntil, until > Date() { return q }
        if s.needsAttention { return "!" }
        switch s.state {
        case .celebrating: return "done"
        case .confused:    return "?"
        default:           return nil
        }
    }
    private func isQuip(_ s: SessionData) -> Bool {
        if let until = s.quipUntil, until > Date(), s.quip != nil { return true }
        return false
    }
    private func bubbleColor(_ s: SessionData) -> Color {
        if isQuip(s) { return .white }   // sarcasm reads best as black-on-white
        if s.needsAttention || s.state == .confused {
            return Color(red: 1.0, green: 0.8, blue: 0.2)
        }
        return Color(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255)
    }

    // MARK: - Expansion content (dark, on the black island)

    @ViewBuilder
    private func expansionContent(_ expansion: IslandLayout.Expansion) -> some View {
        switch expansion {
        case .none:
            EmptyView()
        case .permission(let s, let req):
            permissionContent(s, req)
        case .attention(let s):
            attentionContent(s)
        case .details(let s):
            detailsContent(s)
        }
    }

    private func permissionContent(_ s: SessionData, _ req: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerLine(s.projectName, "needs approval")
            Text(req.toolRawName)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            if !req.preview.isEmpty {
                Text(req.preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 10) {
                darkPill("Deny", filled: false) { onDeny(req) }.frame(width: 84)
                darkPill("Approve", filled: true) { onApprove(req) }.frame(maxWidth: .infinity)
            }
        }
    }

    private func attentionContent(_ s: SessionData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerLine(s.projectName, "needs you")
            Text(s.attentionMessage ?? "Claude is waiting for you")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            darkPill("Open in Claude Code", filled: true) { onFocusTerminal(s.id) }.frame(maxWidth: .infinity)
        }
    }

    private func detailsContent(_ s: SessionData) -> some View {
        let session = model.tokensFor(s)
        let chosen: TokenStats? = {
            switch tokenMode {
            case .session:  return session
            case .today:    return model.todayStats
            case .fiveHour: return model.fiveHourStats
            }
        }()
        let accent = Color(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255)
        return VStack(alignment: .leading, spacing: 6) {
            // Session ("chat") name, prominent.
            Text(session?.title ?? s.projectName)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1).truncationMode(.tail)
            Text("\(s.projectName) · \(stateLabel(s.state))")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                .lineLimit(1).truncationMode(.middle)
            detailRow("Activity", "\(s.toolCount) tool\(s.toolCount == 1 ? "" : "s")")
            detailRow("Model", session?.model.map(prettyModel) ?? (s.model.isEmpty ? "—" : s.model))
            // token window picker
            HStack(spacing: 5) {
                ForEach(TokenMode.allCases, id: \.self) { m in
                    Text(m.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tokenMode == m ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(tokenMode == m ? accent : Color.white.opacity(0.12)))
                        .contentShape(Rectangle())
                        .onTapGesture { tokenMode = m }
                }
            }
            detailRow("Tokens", tokensText(chosen))
            detailRow("Cost", dollarsText(chosen))
            darkPill("Open in Claude Code", filled: true) { onFocusTerminal(s.id) }
                .padding(.top, 2)
        }
    }

    // MARK: - Bits

    private func headerLine(_ project: String, _ trailing: String) -> some View {
        HStack {
            Text(project).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.white)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(trailing).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5)).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func darkPill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        let accent = Color(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255)
        return Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(filled ? .black : .white)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(filled ? accent : Color.white.opacity(0.12)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func stateLabel(_ s: SessionState) -> String {
        switch s {
        case .idle, .idleWaiting:       return "waiting"
        case .working:                  return "working"
        case .thinking:                 return "thinking"
        case .celebrating:              return "done"
        case .confused:                 return "hit an error"
        case .waitingPermission:        return "needs approval"
        }
    }

    private func prettyModel(_ m: String) -> String {
        let l = m.lowercased()
        if l.contains("opus") { return "Opus" }
        if l.contains("sonnet") { return "Sonnet" }
        if l.contains("haiku") { return "Haiku" }
        return m
    }

    private func tokensText(_ t: TokenStats?) -> String {
        guard let t, t.hasTokens else { return "—" }
        func k(_ n: Int?) -> String { guard let n else { return "0" }; return n >= 1000 ? "\(n/1000)k" : "\(n)" }
        return "\(k(t.input)) in · \(k(t.output)) out"
    }

    private func dollarsText(_ t: TokenStats?) -> String {
        guard let d = t?.dollars(pricing: ModelPrice.table) else { return "—" }
        return d < 0.01 ? "<$0.01" : String(format: "$%.2f", d)
    }
}

/// Bridges the StateEngine actor into SwiftUI, plus island UI state (click selection, notch height,
/// and a small token cache so the details view doesn't read the transcript on every redraw).
@MainActor
final class StateBridge: ObservableObject {
    @Published var sessions: [SessionData] = []
    @Published var expandedSessionID: SessionID?
    @Published var notchHeight: CGFloat = 32

    private var tokenCache: [SessionID: TokenStats] = [:]
    /// Cross-session aggregates for the today / 5h token modes (computed lazily on popup open).
    private(set) var todayStats: TokenStats?
    private(set) var fiveHourStats: TokenStats?
    private var aggregatesAt: Date = .distantPast
    private let engine: StateEngine
    private var streamTask: Task<Void, Never>?

    init(engine: StateEngine) {
        self.engine = engine
        start()
    }

    deinit { streamTask?.cancel() }

    private func start() {
        streamTask = Task { [engine] in
            for await snapshot in await engine.snapshotStream() {
                await MainActor.run {
                    self.sessions = snapshot.sessions
                    // Drop click selection + token cache for sessions that no longer exist.
                    let ids = Set(snapshot.sessions.map { $0.id })
                    if let e = self.expandedSessionID, !ids.contains(e) { self.expandedSessionID = nil }
                    self.tokenCache = self.tokenCache.filter { ids.contains($0.key) }
                }
            }
        }
    }

    func cacheTokens(_ stats: TokenStats, for id: SessionID) {
        tokenCache[id] = stats
        objectWillChange.send()   // tokenCache isn't @Published; nudge the view to re-read
    }
    func tokensFor(_ s: SessionData) -> TokenStats? { tokenCache[s.id] }

    func cacheAggregates(today: TokenStats, fiveHour: TokenStats) {
        todayStats = today; fiveHourStats = fiveHour; aggregatesAt = Date()
        objectWillChange.send()
    }
    /// True if today/5h aggregates are missing or older than 20s (cheap debounce).
    var aggregatesStale: Bool { Date().timeIntervalSince(aggregatesAt) > 20 }
}
