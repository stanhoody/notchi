import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders every sprite animation × skin to PNG strips + animated GIFs into an asset folder,
/// so the art can be reviewed outside the running product. Run: `notchi --export-assets [dir]`.
enum AssetExporter {

    private static let scale = 12
    private static let pad = 2   // grid cells of breathing room around the sprite

    // body / eye / accent colors (product defaults)
    // body/shadow/light are derived per-skin from CreatureSkin.bodyHex (see renderFrame).
    private static let eye  = CGColor(red: 0x12/255, green: 0x0A/255, blue: 0x05/255, alpha: 1)
    private static let accent = CGColor(red: 0xC6/255, green: 0xFF/255, blue: 0x00/255, alpha: 1)
    private static let bg = CGColor(red: 0, green: 0, blue: 0, alpha: 1)   // island black

    private static let anims: [(name: String, anim: SpriteAnimation, frames: Int)] = [
        ("idle",        .idleStatic, 1),
        ("waiting",     .waiting, 12),
        ("attention",   .attention, 12),
        ("thinking",    .thinking, 12),
        ("planning",    .planning, 12),
        ("celebrate",   .celebrate, 12),
        ("confused",    .confused, 12),
        ("sleeping",    .sleeping, 12),
        ("work-edit",   .working(.edit, tired: false), 12),
        ("work-bash",   .working(.bash, tired: false), 12),
        ("work-read",   .working(.read, tired: false), 12),
        ("work-web",    .working(.web, tired: false), 12),
        ("work-other",  .working(.other, tired: false), 12),
        ("work-tired",  .working(.edit, tired: true), 12),
    ]

    static func run(dir: String) -> Int32 {
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        do {
            for skin in CreatureSkin.allCases {
                let skinDir = root.appendingPathComponent(skin.rawValue, isDirectory: true)
                let gifDir = skinDir.appendingPathComponent("gif", isDirectory: true)
                let stripDir = skinDir.appendingPathComponent("strip", isDirectory: true)
                try fm.createDirectory(at: gifDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: stripDir, withIntermediateDirectories: true)

                var contactRows: [[CGImage]] = []
                for a in anims {
                    let imgs = (0..<a.frames).map { renderFrame(a.anim, tick: $0, skin: skin) }
                    // animated GIF
                    if a.frames > 1 {
                        writeGIF(imgs, fps: a.anim.fps, to: gifDir.appendingPathComponent("\(a.name).gif"))
                    }
                    // horizontal strip PNG
                    writePNG(stripHorizontally(imgs), to: stripDir.appendingPathComponent("\(a.name).png"))
                    contactRows.append(imgs)
                }
                // one contact sheet: first frame of each anim, in a grid
                let firsts = contactRows.map { $0[0] }
                writePNG(grid(firsts, columns: 5), to: skinDir.appendingPathComponent("_contact.png"))
            }
            writeReadme(root)
            FileHandle.standardError.write(Data("Exported assets to \(root.path)\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Rendering

    private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
    private static func blend(_ c: (CGFloat, CGFloat, CGFloat), _ f: CGFloat, toward t: CGFloat) -> CGColor {
        CGColor(red: c.0 + (t - c.0) * f, green: c.1 + (t - c.1) * f, blue: c.2 + (t - c.2) * f, alpha: 1)
    }

    private static func renderFrame(_ anim: SpriteAnimation, tick: Int, skin: CreatureSkin) -> CGImage {
        let grid = SpriteCompositor.frame(anim, tick: tick, skin: skin)
        let base = rgb(skin.bodyHex)
        let bodyC = CGColor(red: base.0, green: base.1, blue: base.2, alpha: 1)
        let shadowC: CGColor = {
            if let h = skin.shadowHex { let c = rgb(h); return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
            return blend(base, 0.40, toward: 0)
        }()
        let lightC: CGColor = {
            if let h = skin.lightHex { let c = rgb(h); return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
            return blend(base, 0.45, toward: 1)
        }()
        let gw = SpriteCompositor.width + pad * 2
        let gh = SpriteCompositor.height + pad * 2
        let w = gw * scale, h = gh * scale
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (row, cells) in grid.enumerated() {
            for (col, cell) in cells.enumerated() where cell != .clear {
                switch cell {
                case .body:   ctx.setFillColor(bodyC)
                case .shadow: ctx.setFillColor(shadowC)
                case .light:  ctx.setFillColor(lightC)
                case .eye:    ctx.setFillColor(eye)
                case .accent: ctx.setFillColor(accent)
                case .clear:  continue
                }
                let x = (col + pad) * scale
                let y = (gh - 1 - (row + pad)) * scale     // CG origin is bottom-left
                ctx.fill(CGRect(x: x, y: y, width: scale, height: scale))
            }
        }
        return ctx.makeImage()!
    }

    private static func stripHorizontally(_ imgs: [CGImage]) -> CGImage {
        guard let first = imgs.first else { fatalError() }
        let fw = first.width, fh = first.height
        let w = fw * imgs.count, h = fh
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, img) in imgs.enumerated() {
            ctx.draw(img, in: CGRect(x: i * fw, y: 0, width: fw, height: fh))
        }
        return ctx.makeImage()!
    }

    private static func grid(_ imgs: [CGImage], columns: Int) -> CGImage {
        guard let first = imgs.first else { fatalError() }
        let fw = first.width, fh = first.height
        let rows = (imgs.count + columns - 1) / columns
        let w = fw * columns, h = fh * rows
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, img) in imgs.enumerated() {
            let cxp = (i % columns) * fw
            let cyp = (rows - 1 - i / columns) * fh
            ctx.draw(img, in: CGRect(x: cxp, y: cyp, width: fw, height: fh))
        }
        return ctx.makeImage()!
    }

    // MARK: - File output

    private static func writePNG(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writeGIF(_ imgs: [CGImage], fps: Double, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, imgs.count, nil) else { return }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        let delay = Swift.max(0.05, 1.0 / fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        for img in imgs { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
        CGImageDestinationFinalize(dest)
    }

    private static func writeReadme(_ root: URL) {
        let names = anims.map { "  - \($0.name)" }.joined(separator: "\n")
        let txt = """
        Notchi sprite assets (generated by `notchi --export-assets`).

        Per skin (blob / cat / bot):
          gif/    — animated GIF per state (loops)
          strip/  — horizontal sprite strip PNG (all frames side by side)
          _contact.png — overview grid (first frame of each state)

        States:
        \(names)

        Colors: body #FF6A00, eyes #0A0A0A, accent #C6FF00, on black island bg.
        Rendered at \(scale)x. Source: SpriteCompositor.swift (programmatic, not hand-drawn).
        """
        try? Data(txt.utf8).write(to: root.appendingPathComponent("README.txt"))
    }
}
