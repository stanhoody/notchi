import SwiftUI

/// Animated creature. Body color comes from the skin; the emote accent is the user's accent.
/// The TimelineView runs at the animation's own fps (not a fixed 12) — idle/sleeping cost far
/// less than working/attention (teardown perf fix).
public struct SpriteView: View {
    let state: SessionState?
    let needsAttention: Bool
    let lastActivity: Date?
    var workingSince: Date? = nil
    var skin: CreatureSkin = .claude
    var pixel: CGFloat = 3
    var speed: Double = 1.0
    var accentColor: Color = Color(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255)

    private let staleAfter: TimeInterval = 90

    public init(state: SessionState?,
                needsAttention: Bool = false,
                lastActivity: Date? = nil,
                workingSince: Date? = nil,
                skin: CreatureSkin = .claude,
                pixel: CGFloat = 3,
                speed: Double = 1.0,
                accentColor: Color = Color(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255)) {
        self.state = state
        self.needsAttention = needsAttention
        self.lastActivity = lastActivity
        self.workingSince = workingSince
        self.skin = skin
        self.pixel = pixel
        self.speed = speed
        self.accentColor = accentColor
    }

    private func animation(now: Date) -> SpriteAnimation {
        if needsAttention { return .attention }
        switch state {
        case .none, .idle:
            return .idleStatic
        case .working(let tool):
            if case .plan = tool { return .planning }
            let tired = workingSince.map { now.timeIntervalSince($0) > 30 } ?? false
            return .working(tool.spriteFamily, tired: tired)
        case .thinking:    return .thinking
        case .celebrating: return .celebrate
        case .confused:    return .confused
        case .waitingPermission: return .attention
        case .idleWaiting:
            let elapsed = lastActivity.map { now.timeIntervalSince($0) } ?? 0
            if elapsed > 300 { return .sleeping }
            return elapsed > staleAfter ? .idleStatic : .waiting
        }
    }

    public var body: some View {
        let w = CGFloat(SpriteCompositor.width) * pixel
        let h = CGFloat(SpriteCompositor.height) * pixel

        let bodyColor = Color(hex: skin.bodyHex)
        let ns = NSColor(bodyColor).usingColorSpace(.sRGB) ?? NSColor.orange
        let shadowColor = skin.shadowHex.map { Color(hex: $0) }
            ?? Color(nsColor: ns.blended(withFraction: 0.40, of: .black) ?? ns)
        let lightColor = skin.lightHex.map { Color(hex: $0) }
            ?? Color(nsColor: ns.blended(withFraction: 0.45, of: .white) ?? ns)
        let eyeColor = Color(red: 0x10/255, green: 0x0A/255, blue: 0x08/255)

        let scheduleFps = max(1.0, animation(now: Date()).fps * speed)
        return TimelineView(.periodic(from: .now, by: 1.0 / scheduleFps)) { context in
            Canvas { gc, _ in
                let anim = animation(now: context.date)
                let fps = max(1.0, anim.fps * speed)
                let tick = Int(context.date.timeIntervalSinceReferenceDate * fps)
                let grid = SpriteCompositor.frame(anim, tick: tick, skin: skin)
                for (y, row) in grid.enumerated() {
                    for (x, cell) in row.enumerated() where cell != .clear {
                        let color: Color
                        switch cell {
                        case .body:   color = bodyColor
                        case .shadow: color = shadowColor
                        case .light:  color = lightColor
                        case .eye:    color = eyeColor
                        case .accent: color = accentColor
                        case .clear:  continue
                        }
                        gc.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                            width: pixel, height: pixel)),
                                with: .color(color))
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .frame(width: w, height: h)
    }
}
