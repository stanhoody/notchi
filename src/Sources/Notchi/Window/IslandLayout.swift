import CoreGraphics
import Foundation

/// Pure geometry for the Dynamic-Island-style notch surface.
///
/// The island is a single black shape centered on the built-in screen, its top flush with the
/// screen edge so it reads as an extension of the physical notch. Characters live in the top
/// band BESIDE the camera (the center `notchWidth` is reserved for the real cutout) and grow
/// outward left/right as sessions accumulate. A request expands the island downward.
public enum IslandLayout {

    /// Pixel scale for characters rendered in the top band (sprite grid is 22×16).
    public static let bandPixel: CGFloat = 1.6
    public static var charWidth: CGFloat { 22 * bandPixel }     // ~35
    public static var charHeight: CGFloat { 16 * bandPixel }    // ~26
    public static let charGap: CGFloat = 6
    public static var charSlot: CGFloat { charWidth + charGap } // ~41

    public static let expandedMinWidth: CGFloat = 340

    /// What the island is currently showing.
    public enum Expansion: Equatable {
        case none
        case permission(SessionData, PermissionRequest)
        case attention(SessionData)
        case details(SessionData)

        var contentHeight: CGFloat {
            switch self {
            case .none:        return 0
            case .permission:  return 156
            case .attention:   return 100
            case .details:     return 234
            }
        }
        var isExpanded: Bool { if case .none = self { return false }; return true }
    }

    /// Decide the expansion from the snapshot + a click-selected session.
    public static func expansion(sessions: [SessionData], clicked: SessionID?) -> Expansion {
        if let s = sessions.first(where: { if case .waitingPermission = $0.state { return true }; return false }),
           case .waitingPermission(let req) = s.state {
            return .permission(s, req)
        }
        if let s = sessions.first(where: { $0.needsAttention }) {
            return .attention(s)
        }
        if let id = clicked, let s = sessions.first(where: { $0.id == id }) {
            return .details(s)
        }
        return .none
    }

    /// right = ceil(n/2), left = floor(n/2) — fill outward, right side first.
    public static func sideCounts(_ n: Int) -> (left: Int, right: Int) {
        ((n) / 2, (n + 1) / 2)
    }

    /// Vertical center for the parent characters (kept at camera level).
    public static func parentCenterY(notchHeight: CGFloat) -> CGFloat {
        max(notchHeight, 30) / 2
    }

    /// Extra height added below the band to host sub-agent companions.
    public static let subAgentRowHeight: CGFloat = 16

    /// The band height. Grows by one mini row when any session has sub-agents.
    public static func bandHeight(notchHeight: CGFloat, hasSubAgents: Bool = false) -> CGFloat {
        max(notchHeight, 30) + (hasSubAgents ? subAgentRowHeight : 0)
    }

    /// Resting island width: camera (notch) reserved center + character slots each side.
    public static func restingWidth(notchWidth: CGFloat, sessionCount n: Int) -> CGFloat {
        guard n > 0 else { return notchWidth }
        let maxSide = max(sideCounts(n).left, sideCounts(n).right)
        return notchWidth + 2 * CGFloat(maxSide) * charSlot
    }

    /// Full window size for the current state. Height grows when expanded.
    public static func windowSize(notchWidth: CGFloat, notchHeight: CGFloat,
                                  sessionCount: Int, expansion: Expansion,
                                  hasSubAgents: Bool = false) -> CGSize {
        let band = bandHeight(notchHeight: notchHeight, hasSubAgents: hasSubAgents)
        let resting = restingWidth(notchWidth: notchWidth, sessionCount: sessionCount)
        if expansion.isExpanded {
            return CGSize(width: max(resting, expandedMinWidth), height: band + expansion.contentHeight)
        }
        return CGSize(width: resting, height: band)
    }

    /// Should the island be visible at all? Hidden when nothing is happening.
    public static func isVisible(sessionCount: Int, expansion: Expansion) -> Bool {
        sessionCount > 0 || expansion.isExpanded
    }

    /// Character center positions in window-local top-left coordinates, ordered to match
    /// the (already priority-sorted) sessions. Index 0,2,4 → right of camera; 1,3,5 → left.
    public static func charPositions(windowWidth W: CGFloat, notchWidth: CGFloat,
                                     centerY cy: CGFloat, count: Int) -> [CGPoint] {
        let cx = W / 2
        let notchHalf = notchWidth / 2
        var pts: [CGPoint] = []
        for i in 0..<count {
            let k = CGFloat(i / 2)
            let x: CGFloat = (i % 2 == 0)
                ? cx + notchHalf + (k + 0.5) * charSlot     // right
                : cx - notchHalf - (k + 0.5) * charSlot     // left
            pts.append(CGPoint(x: x, y: cy))
        }
        return pts
    }
}
