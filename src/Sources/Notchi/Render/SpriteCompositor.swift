import Foundation

/// Pixel-art creature compositor — readability-first redesign.
///
/// Principles (from pixel-art references): recognizable by SILHOUETTE; form via internal
/// shading not detail; the ACTION is shown by a distinct emote above the head, so every state
/// reads differently (not "always dots"). The body is hand-authored per skin for a clean shape;
/// emotes are shared. Canvas 24×18, center column 12.
public enum Cell: UInt8, Sendable {
    case clear = 0
    case body  = 1   // main orange
    case shadow = 2  // darker orange — gives the blob form on the black island
    case light  = 3  // highlight
    case eye    = 4  // dark eyes
    case accent = 5  // acid-lime — emotes, props
}

public enum CreatureSkin: String, Sendable, CaseIterable {
    case claude, skull, dog, robot, spacecat, invader, cactus, flower, jobs

    public var display: String {
        switch self {
        case .claude:   return "Claude"
        case .skull:    return "Skull"
        case .dog:      return "Dog"
        case .robot:    return "Robot"
        case .spacecat: return "Space Cat"
        case .invader:  return "Invader"
        case .cactus:   return "Cactus"
        case .flower:   return "Flower"
        case .jobs:     return "Jobs"
        }
    }

    /// Each character's primary color. Shadow/light derive from it unless overridden below;
    /// the emote accent stays the user's accent color.
    public var bodyHex: String {
        switch self {
        case .claude:   return "#B97A56"   // warm tan (the Claude terminal pet)
        case .skull:    return "#E6E2D3"   // bone
        case .dog:      return "#A56A3A"   // brown
        case .robot:    return "#A2ABB3"   // steel
        case .spacecat: return "#A06CE0"   // purple
        case .invader:  return "#5BE06B"   // alien green
        case .cactus:   return "#4E9A4E"   // cactus green
        case .flower:   return "#F2C24B"   // flower center (yellow)
        case .jobs:     return "#4A4A4A"   // grey turtleneck
        }
    }

    /// Explicit shadow color (the `x` cell). nil → derived darker shade of body.
    public var shadowHex: String? {
        switch self {
        case .flower:   return "#3E8E41"   // green stem + leaves
        default:        return nil
        }
    }

    /// Explicit "light" color (the `h` cell). nil → derived lighter shade of body.
    /// Repurposed for multi-color characters (pot, skin).
    public var lightHex: String? {
        switch self {
        case .cactus:   return "#9C5A33"   // terracotta pot
        case .flower:   return "#9C5A33"   // terracotta pot
        case .jobs:     return "#D8A878"   // skin / bald head
        default:        return nil
        }
    }
}

public enum SpriteAnimation: Equatable, Sendable {
    case idleStatic
    case waiting
    case attention
    case thinking
    case planning
    case working(SpriteFamily, tired: Bool)
    case celebrate
    case confused
    case sleeping

    var fps: Double {
        switch self {
        case .idleStatic: return 1
        case .waiting:    return 4
        case .attention:  return 8
        case .thinking:   return 3
        case .planning:   return 3
        case .working:    return 6
        case .celebrate:  return 8
        case .confused:   return 4
        case .sleeping:   return 2
        }
    }
}

public struct SpriteCompositor {

    public static let width = 24
    public static let height = 18
    private static let bodyOX = 5          // body grids are 14 wide → centered in 24
    private static let bodyOY = 3

    public static func frame(_ anim: SpriteAnimation, tick: Int, skin: CreatureSkin = .claude) -> [[Cell]] {
        var g = blank()

        // pose modifiers per state
        var blink = false, sleepEyes = false, happyEyes = false, droopy = false
        var hop = 0
        var arms: ArmPose = .rest
        switch anim {
        case .idleStatic:                 blink = (tick % 16) == 15
        case .waiting:                    arms = (tick % 2 == 0) ? .wave1 : .wave2
        case .attention:                  arms = (tick % 2 == 0) ? .wave1 : .wave2
        case .thinking:                   break
        case .planning:                   break
        case .working(_, let t):          droopy = t
        case .celebrate:                  happyEyes = true; hop = (tick % 2 == 0) ? -1 : 0; arms = .up
        case .confused:                   break
        case .sleeping:                   sleepEyes = true
        }

        stampBody(&g, skin: skin, yOffset: hop, blink: blink, sleepEyes: sleepEyes,
                  happyEyes: happyEyes, droopy: droopy)
        stampArms(&g, skin: skin, pose: arms, yOffset: hop)
        stampEmote(&g, anim: anim, tick: tick)
        return g
    }

    // MARK: - ASCII debug

    public static func ascii(_ anim: SpriteAnimation, frames: Int) -> String {
        var out = ""
        for t in 0..<frames {
            out += "frame \(t):\n"
            for row in frame(anim, tick: t) {
                out += String(row.map { c -> Character in
                    switch c {
                    case .clear: return "."; case .body: return "O"; case .shadow: return "x"
                    case .light: return "o"; case .eye: return "e"; case .accent: return "*"
                    }
                }) + "\n"
            }
            out += "\n"
        }
        return out
    }

    // MARK: - Grid

    private static func blank() -> [[Cell]] {
        Array(repeating: Array(repeating: Cell.clear, count: width), count: height)
    }
    private static func set(_ g: inout [[Cell]], _ x: Int, _ y: Int, _ c: Cell) {
        guard y >= 0, y < height, x >= 0, x < width else { return }
        g[y][x] = c
    }

    // MARK: - Bodies (hand-authored, 14 wide). Legend: O body, x shadow, h light, . clear.
    // Eyes are stamped procedurally so blink/sleep/look variants stay easy.

    // CLAUDE — the boxy tan terminal pet: rectangular body, square eyes, three stubby legs.
    private static let claudeBody: [String] = [
        "..OOOOOOOOOO..",
        ".OOOOOOOOOOOO.",
        "OOOOOOOOOOOOOO",
        "OOOOOOOOOOOOhO",
        "OOOOOOOOOOOxxO",
        "OOOOOOOOOOxxxO",
        "OOOOOOOOOxxxxO",
        ".OOOOOOOOOOOO.",
        "..OO..OO..OO..",
        "..OO..OO..OO..",
    ]
    // SKULL — bone dome, hollow sockets, teeth.
    private static let skullBody: [String] = [
        "...OOOOOOOO...",
        "..OOOOOOOOOO..",
        ".OOOOOOOOOOOO.",
        ".OOOOOOOOOOOO.",
        ".OOOOOOOOOOOO.",
        "..OOOOOOOOOO..",
        "..OOOOOOOOOO..",
        "..O.OO..OO.O..",
        "...OO.OO.OO...",
    ]
    // DOG — ears up top, snout + dark nose.
    private static let dogBody: [String] = [
        "OO..........OO",
        "OOO........OOO",
        ".OOOOOOOOOOOO.",
        "OOOOOOOOOOOOOO",
        "OOOOOOOOOOOOOO",
        "OOOOOhhhhOOOOO",
        "OOOOhheehhOOOO",
        "OOOOOhhhhOOOOO",
        ".OOOOOOOOOOOx.",
        "..OO..OO..OO..",
    ]
    // ROBOT — square head, antenna, grille mouth, peg legs.
    private static let robotBody: [String] = [
        "......*.......",
        "......O.......",
        "OOOOOOOOOOOOOO",
        "OOOOOOOOOOOOOO",
        "OOOOOOOOOOOOOO",
        "OOOhhhhhhhhOOO",
        "OOOOOOOOOOOxxO",
        "OOOOOOOOOOxxxO",
        ".OO......OO...",
        ".OO......OO...",
    ]
    // SPACE CAT — pointy ears, sparkle cheeks.
    private static let spacecatBody: [String] = [
        ".OO........OO.",
        ".OOO......OOO.",
        "..OOOOOOOOOO..",
        ".OOOOOOOOOOOO.",
        "OOOOOOOOOOOOOO",
        "OOOO*OOOO*OOOO",
        "OOOOOOOOOOOOOO",
        ".OOOOOOOOOOxx.",
        "..OOOOOOOOOO..",
        "...OO....OO...",
    ]
    // INVADER — classic space-invader silhouette: antennae, notched arms, splayed legs.
    private static let invaderBody: [String] = [
        "...O......O...",
        "....O....O....",
        "..OOOOOOOOOO..",
        ".OOOOOOOOOOOO.",
        "OOOOOOOOOOOOOO",
        "OOO.OOOOOO.OOO",
        "OOOOOOOOOOOOOO",
        "O.OOOOOOOOOO.O",
        "O.O........O.O",
        "...OO....OO...",
    ]

    // CACTUS — saguaro with two arm-pads, accent bud on top, terracotta pot (h).
    private static let cactusBody: [String] = [
        "......**......",
        ".....OOOO.....",
        "....OOOOOO....",
        "....OOOOOO..OO",
        "OO..OOOOOO..OO",
        "OO..OOOOOO..O.",
        ".O..OOOOOO....",
        "....OOOOOO....",
        "....OOOOOO....",
        "...OOOOOOOO...",
        "...hhhhhhhh...",
        "..hhhhhhhhhh..",
    ]
    // FLOWER — petals (accent *), yellow center (O) with the face, green stem/leaves (x), pot (h).
    private static let flowerBody: [String] = [
        "...*..*..*....",
        "..*OOOOOOOO*..",
        "..*OOOOOOOO*..",
        "..*OOOOOOOO*..",
        "...*OOOOOO*...",
        "....*OOOO*....",
        ".....xOOx.....",
        "...xxxOOxxx...",
        ".....xOOx.....",
        ".....xOOx.....",
        "...hhhhhhhh...",
        "..hhhhhhhhhh..",
    ]
    // JOBS — bald skin head (h), dark round glasses (eyes), grey turtleneck (O).
    private static let jobsBody: [String] = [
        "....hhhhhh....",
        "...hhhhhhhh...",
        "..hhhhhhhhhh..",
        "..hhhhhhhhhh..",
        "..hhhhhhhhhh..",
        "...hhhhhhhh...",
        "....hhhhhh....",
        "...OOOOOOOO...",
        "..OOOOOOOOOO..",
        "..OOOOOOOOOO..",
        "..OOOOOOOOOO..",
        "..OOOOOOOOOO..",
    ]

    private static func body(for skin: CreatureSkin) -> [String] {
        switch skin {
        case .claude:   return claudeBody
        case .skull:    return skullBody
        case .dog:      return dogBody
        case .robot:    return robotBody
        case .spacecat: return spacecatBody
        case .invader:  return invaderBody
        case .cactus:   return cactusBody
        case .flower:   return flowerBody
        case .jobs:     return jobsBody
        }
    }

    // eye row within the body grid + columns (left/right eye start), per skin
    private static func eyeSpec(_ skin: CreatureSkin) -> (row: Int, lx: Int, rx: Int) {
        switch skin {
        case .claude:   return (2, 3, 9)
        case .skull:    return (2, 3, 9)
        case .dog:      return (3, 2, 9)
        case .robot:    return (3, 2, 9)
        case .spacecat: return (3, 2, 9)
        case .invader:  return (4, 3, 9)
        case .cactus:   return (4, 4, 7)
        case .flower:   return (2, 4, 7)
        case .jobs:     return (3, 3, 8)   // dark round glasses on the skin head
        }
    }

    private static func stampBody(_ g: inout [[Cell]], skin: CreatureSkin, yOffset: Int,
                                  blink: Bool, sleepEyes: Bool, happyEyes: Bool, droopy: Bool) {
        let rows = body(for: skin)
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() {
                let cell: Cell? = {
                    switch ch { case "O": return .body; case "x": return .shadow
                                case "h": return .light; case "*": return .accent; default: return nil }
                }()
                if let cell { set(&g, bodyOX + c, bodyOY + r + yOffset, cell) }
            }
        }
        // eyes
        let e = eyeSpec(skin)
        let ey = bodyOY + e.row + yOffset
        let lx = bodyOX + e.lx, rx = bodyOX + e.rx
        stampEye(&g, x: lx, y: ey, blink: blink, sleep: sleepEyes, happy: happyEyes, droopy: droopy, leftSide: true)
        stampEye(&g, x: rx, y: ey, blink: blink, sleep: sleepEyes, happy: happyEyes, droopy: droopy, leftSide: false)
    }

    private static func stampEye(_ g: inout [[Cell]], x: Int, y: Int,
                                 blink: Bool, sleep: Bool, happy: Bool, droopy: Bool, leftSide: Bool) {
        if blink || sleep || droopy {
            set(&g, x, y + 1, .eye); set(&g, x + 1, y + 1, .eye)   // closed line
            return
        }
        if happy {
            // ^ shape
            set(&g, x, y + 1, .eye); set(&g, x + 1, y, .eye); set(&g, x + 2, y + 1, .eye)
            return
        }
        // 2×2 dark eye with a light glint
        for dx in 0...1 { for dy in 0...1 { set(&g, x + dx, y + dy, .eye) } }
        set(&g, x + (leftSide ? 1 : 0), y, .light)
    }

    // MARK: - Arms

    private enum ArmPose { case rest, wave1, wave2, up }

    private static func stampArms(_ g: inout [[Cell]], skin: CreatureSkin, pose: ArmPose, yOffset: Int) {
        let leftX = bodyOX + 1, rightX = bodyOX + 12
        let armY = bodyOY + 7 + yOffset
        switch pose {
        case .rest:
            set(&g, leftX - 1, armY, .body); set(&g, leftX - 1, armY + 1, .shadow)
            set(&g, rightX + 1, armY, .body); set(&g, rightX + 1, armY + 1, .shadow)
        case .wave1:
            set(&g, leftX - 1, armY, .body); set(&g, leftX - 1, armY + 1, .body)
            // right arm up
            for k in 0..<3 { set(&g, rightX + 1 + k, armY - 1 - k, .body) }
            set(&g, rightX + 3, armY - 3, .accent)
        case .wave2:
            for k in 0..<3 { set(&g, rightX + 1 + k, armY - 2 - k, .body) }
            set(&g, rightX + 3, armY - 4, .accent)
            set(&g, leftX - 1, armY, .body); set(&g, leftX - 1, armY + 1, .body)
        case .up:
            for k in 0..<3 { set(&g, leftX - 1 - k, armY - 1 - k, .body) }
            for k in 0..<3 { set(&g, rightX + 1 + k, armY - 1 - k, .body) }
            set(&g, leftX - 3, armY - 3, .accent); set(&g, rightX + 3, armY - 3, .accent)
        }
    }

    // MARK: - Emotes (the action signal). Drawn top-right as a small lime icon in a dark bubble.

    private static func stampEmote(_ g: inout [[Cell]], anim: SpriteAnimation, tick: Int) {
        // bubble anchor (top-right)
        let ox = 16, oy = 0
        func a(_ x: Int, _ y: Int) { set(&g, ox + x, oy + y, .accent) }
        func dark(_ x: Int, _ y: Int) { set(&g, ox + x, oy + y, .eye) }

        switch anim {
        case .idleStatic, .waiting:
            return  // no emote — calm

        case .thinking:
            let n = (tick % 3) + 1
            for i in 0..<n { a(1 + i * 2, 3) }

        case .planning:
            // lightbulb
            let on = tick % 2 == 0
            if on { a(2, 0); a(1, 1); a(3, 1); a(1, 2); a(3, 2); a(2, 1) } else { dark(2,0); dark(1,1); dark(3,1); dark(1,2); dark(3,2) }
            a(2, 3) // base
            if on { a(0, 0); a(4, 0) } // rays

        case .working(let fam, _):
            switch fam {
            case .edit:   // keyboard: 2 rows of keys
                for x in 0...4 { a(x, 2); a(x, 4) }
            case .bash:   // terminal window: box outline + ">" prompt + blinking cursor
                for x in 0...5 { a(x, 0); a(x, 5) }                 // top + bottom
                for y in 1...4 { a(0, y); a(5, y) }                 // sides
                a(1, 2); a(2, 3)                                    // ">" prompt chevron
                if tick % 2 == 0 { a(3, 3); a(4, 3) }               // blinking cursor
            case .read:   // magnifier: round glass + handle
                a(1,0);a(2,0); a(0,1);a(3,1); a(0,2);a(3,2); a(1,3);a(2,3); a(3,4);a(4,5)
            case .web:    // globe
                a(1,0);a(2,0); a(0,1);a(3,1); a(0,2);a(1,2);a(2,2);a(3,2); a(0,3);a(3,3); a(1,4);a(2,4)
            case .plan:   a(2,0); a(2,1); a(2,2)
            case .other:  // cog: hollow ring + 4 nub teeth (distinct from the filled star)
                a(2,0); a(2,5)                                      // top/bottom teeth
                a(0,2); a(5,2)                                      // left/right teeth (shifted in)
                a(1,1);a(2,1);a(3,1); a(1,4);a(2,4);a(3,4)          // ring top/bottom
                a(1,2);a(4,2); a(1,3);a(4,3)                        // ring sides (hollow center)
            }

        case .celebrate:  // star
            a(2,0); a(0,2);a(1,2);a(2,2);a(3,2);a(4,2); a(1,3); a(3,3); a(0,4); a(4,4)

        case .confused:   // ?
            a(1,0);a(2,0); a(3,1); a(2,2); a(2,4)

        case .sleeping:   // Zzz rising (small → big as they float up)
            let s = tick % 3
            if s >= 0 { a(0, 4); a(1, 4); a(1, 5); a(0, 6) }       // small z (bottom)
            if s >= 1 { a(3, 2); a(4, 2); a(4, 3); a(3, 4) }       // mid z
            if s >= 2 { a(5, 0); a(6, 0); a(6, 1); a(5, 2) }       // big z (top)

        case .attention:  // !
            a(2, 0); a(2, 1); a(2, 2); a(2, 4)
        }
    }
}
