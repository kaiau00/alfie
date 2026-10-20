#!/usr/bin/env swift
// Memoe's mark, rendered everywhere it is needed from one description of it.
//
// The mark is the wave from `brand/memoe-mark.svg`: a single stroked path —
// stub, valley, arch, valley, arch, stub — with round caps and joins, in the
// brand blue on the brand near-black. It replaced the old "M with an
// equaliser under it" when the product was renamed to Memoe on 2026-09-22.
//
// Everything downstream is generated here so the site and the app can never
// disagree about what the product looks like:
//
//   Resources/Moe.iconset/      the app icon, every size macOS asks for
//   Resources/Moe.icns          built from it, by iconutil, at the end
//   Resources/icon-preview*.png what it looks like, for a human
//   site/assets/icon-{16,32,180,512}.png   the favicons
//   site/assets/moe-logo-{120,512}.png     opaque, for the docs header and
//                                          the brand cards
//   site/assets/og.png          the link preview, 1200x630
//
// and, only when asked (`webstore <dir>`, see "Chrome Web Store" below), the
// Chrome extension's icons and its store pictures.
//
// `site/favicon.ico` is built from these by `scripts/make-favicon.py`, which
// this script does not do because an ICO container is three PNGs and a header
// and Python already has the code.
//
// The filename `Moe.icns` does not change: `CFBundleIconFile` is `Moe`, and
// `scripts/test-release.sh` pins that. The artwork changed; the slot did not.
//
// Usage:  swift scripts/make-icon.swift
import AppKit

// ---- The mark ---------------------------------------------------------------
// Coordinates are `brand/memoe-mark.svg`'s, y measured DOWN as SVG does, and
// converted at the last moment. Every arc in that file is a semicircle — each
// one's endpoints share a y and are exactly 2r apart — so each is named here by
// its centre and which way it bulges, which is both shorter and impossible to
// get subtly wrong the way a re-typed arc flag is.
//
// The centreline's own box is 212 x 129; the stroke adds its full width to
// each dimension, which is where the SVG's 246 x 163 viewBox comes from.
let markCoreW: CGFloat = 212, markCoreH: CGFloat = 129
let markStroke: CGFloat = 34
let markX0: CGFloat = 11, markY0: CGFloat = 15   // top-left of the centreline box

enum Seg {
    case line(CGFloat, CGFloat)                      // to (x, y)
    case arc(cx: CGFloat, r: CGFloat, up: Bool)      // semicircle to (cx + r, y)
}

let markStart = CGPoint(x: 11, y: 93)
let markSegs: [Seg] = [
    .line(11, 117.5),
    .arc(cx: 31.5,  r: 20.5, up: false),   // valley
    .line(52, 46),
    .arc(cx: 83,    r: 31,   up: true),    // arch
    .line(114, 120),
    .arc(cx: 138,   r: 24,   up: false),   // valley
    .line(162, 73.5),
    .arc(cx: 192.5, r: 30.5, up: true),    // arch
    .line(223, 129),
]

/// The mark's centreline, scaled by `s` and placed with its box's top-left at
/// `at` measured from the top of a canvas `canvasH` tall, in Cocoa coordinates.
func markCentreline(scale s: CGFloat, at origin: CGPoint, canvasH: CGFloat) -> CGPath {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (x - markX0) * s,
                y: canvasH - (origin.y + (y - markY0) * s))
    }
    let path = CGMutablePath()
    path.move(to: P(markStart.x, markStart.y))
    var cursor = markStart
    for seg in markSegs {
        switch seg {
        case .line(let x, let y):
            path.addLine(to: P(x, y)); cursor = CGPoint(x: x, y: y)
        case .arc(let cx, let r, let up):
            // Drawn in Cocoa space, so "up" on screen is the +y half. Sweeping
            // from pi to 0 clockwise passes through pi/2 (the top); sweeping
            // anticlockwise passes through 3pi/2 (the bottom).
            let c = P(cx, cursor.y)
            path.addArc(center: c, radius: r * s,
                        startAngle: .pi, endAngle: 0, clockwise: up)
            cursor = CGPoint(x: cx + r, y: cursor.y)
        }
    }
    return path
}

/// Per-size tuning. A hairline survives 512 px and vanishes at 16, so the mark
/// grows and its stroke thickens as the canvas shrinks. `width` is the fraction
/// of the tile the mark spans; `strokeK` multiplies the stroke; `lift` mixes
/// the ink toward white.
struct Tuning { let width: CGFloat; let strokeK: CGFloat; let lift: CGFloat }
func tuning(for size: Int) -> Tuning {
    switch size {
    case ..<24:  return Tuning(width: 0.90, strokeK: 1.42, lift: 0.40)
    case ..<48:  return Tuning(width: 0.84, strokeK: 1.20, lift: 0.26)
    case ..<128: return Tuning(width: 0.74, strokeK: 1.06, lift: 0.10)
    default:     return Tuning(width: 0.70, strokeK: 1.00, lift: 0.0)
    }
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// Sampled from the owner's reference image, 2026-09-22 (brand/LOGO.md).
let brandBlue  = rgb(0x53739A)
let brandBlack = rgb(0x050504)
let brandCream = rgb(0xFEF6EB)
// The tile carries a whisper of a gradient rather than a flat fill: flat
// near-black reads as a hole at 512 px beside other Mac icons.
let bgTop    = rgb(0x111114)
let bgBottom = rgb(0x040404)

/// The brand blue, lightened toward white. At 16 px on near-black the flat
/// brand value is too dim to read as a shape, so the small sizes borrow some
/// of the contrast the large ones do not need.
func blue(lift: CGFloat) -> NSColor {
    guard lift > 0 else { return brandBlue }
    return brandBlue.blended(withFraction: lift, of: .white) ?? brandBlue
}

// ---- Drawing ----------------------------------------------------------------
/// macOS icon shape: continuous-corner ("squircle") rounded square, corner
/// radius ~22% of the side. Approximated with the common cubic-Bezier fit.
func squircle(in r: CGRect) -> NSBezierPath {
    let rad = r.width * 0.22
    let k: CGFloat = 1.28  // extend the control handles past a circular arc
    let p = NSBezierPath()
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    let c = rad * k, a = rad * 0.4
    p.move(to: NSPoint(x: x0 + c, y: y1))
    p.line(to: NSPoint(x: x1 - c, y: y1))
    p.curve(to: NSPoint(x: x1, y: y1 - c), controlPoint1: NSPoint(x: x1 - a, y: y1), controlPoint2: NSPoint(x: x1, y: y1 - a))
    p.line(to: NSPoint(x: x1, y: y0 + c))
    p.curve(to: NSPoint(x: x1 - c, y: y0), controlPoint1: NSPoint(x: x1, y: y0 + a), controlPoint2: NSPoint(x: x1 - a, y: y0))
    p.line(to: NSPoint(x: x0 + c, y: y0))
    p.curve(to: NSPoint(x: x0, y: y0 + c), controlPoint1: NSPoint(x: x0 + a, y: y0), controlPoint2: NSPoint(x: x0, y: y0 + a))
    p.line(to: NSPoint(x: x0, y: y1 - c))
    p.curve(to: NSPoint(x: x0 + c, y: y1), controlPoint1: NSPoint(x: x0, y: y1 - a), controlPoint2: NSPoint(x: x0 + a, y: y1))
    p.close()
    return p
}

/// The mark alone, stroked and centred in a square canvas `size` across.
func markPath(canvas size: CGFloat, _ t: Tuning) -> CGPath {
    // Fit the *stroked* width — the stroke adds its whole width to the box, so
    // solving for it is what keeps the round caps inside the tile.
    let s = t.width * size / (markCoreW + markStroke * t.strokeK)
    let w = markStroke * t.strokeK * s
    let boxW = markCoreW * s + w, boxH = markCoreH * s + w
    let origin = CGPoint(x: (size - boxW) / 2 + w / 2, y: (size - boxH) / 2 + w / 2)
    return markCentreline(scale: s, at: origin, canvasH: size)
        .copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// `opaque` drops the transparent margin and fills the whole square, for the
/// places that composite the icon onto an unknown background — the docs header
/// and the brand cards.
///
/// `tight` keeps the squircle but shrinks the margin around it. Apple's icon
/// template reserves ~10% for the Dock's shadow and its hover growth; a browser
/// draws a favicon into a hard 16 or 32 pixel box with no such allowance, so
/// that margin is simply 20% of the linear size thrown away at exactly the
/// size that can least afford it.
func render(size: Int, opaque: Bool = false, tight: Bool = false) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    NSColor.clear.set(); NSRect(x: 0, y: 0, width: s, height: s).fill()

    // Apple's template leaves ~10% transparent margin around the squircle.
    let inset = opaque ? 0 : s * (tight ? 0.02 : 0.10)
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = squircle(in: rect)

    if !opaque {
        // Soft outer glow / shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        bgBottom.set(); shape.fill()
        ctx.restoreGState()
    }

    ctx.saveGState()
    shape.addClip()
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: rect, angle: -90)
    // Faint highlight along the top edge, and an inner rim on the top half.
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.055),
                                        NSColor.white.withAlphaComponent(0.0)],
                               atLocations: [0, 0.30], colorSpace: .deviceRGB)!
    highlight.draw(in: rect, angle: -90)
    ctx.saveGState()
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.addPath(shape.cgPath); ctx.clip(to: CGRect(x: 0, y: rect.midY, width: s, height: s))
    ctx.addPath(shape.cgPath); ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()

    let t = tuning(for: size)
    let ink = blue(lift: t.lift)
    ctx.saveGState()
    shape.addClip()
    // The mark is sized against the squircle, not the whole canvas, so the
    // transparent margin does not shrink it.
    ctx.translateBy(x: rect.minX, y: rect.minY)
    let m = markPath(canvas: rect.width, t)
    if size >= 128 {
        // A breath of the mark's own colour behind it, so it does not look
        // pasted onto the black. Not a drop shadow: the tile is already dark.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: rect.width * 0.035,
                      color: ink.withAlphaComponent(0.45).cgColor)
        ctx.addPath(m); ctx.setFillColor(ink.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(m); ctx.setFillColor(ink.cgColor); ctx.fillPath()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width),
                               pixelsHigh: Int(img.size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: img.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ img: NSImage, to path: String) {
    try! png(img).write(to: URL(fileURLWithPath: path))
}

/// The icon at each size in a row on a light-grey ground, optionally blown up
/// `zoom`x with nearest-neighbour sampling.
func sheet(sizes: [Int], zoom z: Int = 1) -> NSImage {
    let pad = 16
    let w = sizes.reduce(0) { $0 + $1 * z } + pad * (sizes.count + 1)
    let h = (sizes.max() ?? 0) * z + 2 * pad
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor(white: 0.92, alpha: 1).set(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    if z > 1 { NSGraphicsContext.current?.imageInterpolation = .none }
    var x = pad
    for sz in sizes {
        render(size: sz).draw(in: NSRect(x: x, y: pad, width: sz * z, height: sz * z))
        x += sz * z + pad
    }
    img.unlockFocus()
    return img
}

/// Open Graph card: the icon on the left, the name and the tagline on the
/// right. This is the picture every link to the site shows in a feed, so the
/// words are the site's own — the decided tagline, not a second set of words
/// that can drift away from it.
func ogImage() -> NSImage {
    let w: CGFloat = 1200, h: CGFloat = 630
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSGradient(starting: rgb(0x14141a), ending: brandBlack)!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    render(size: 360).draw(in: NSRect(x: 96, y: h / 2 - 180, width: 360, height: 360))
    let para = NSMutableParagraphStyle(); para.lineSpacing = 8
    // NSAttributedString draws from the TOP of the rect it is given, so `y` is
    // the rect's bottom and `box` its height: a tall box pushes the text up.
    func draw(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
              y: CGFloat, box: CGFloat = 220, maxW: CGFloat = 680) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: para]
        NSAttributedString(string: text, attributes: a)
            .draw(in: NSRect(x: 458, y: y, width: maxW, height: box))
    }
    draw("Memoe", 92, .bold, brandCream, y: h - 336)
    draw("No chat box. Talk from any app,\nand it talks back.", 38, .regular,
         brandCream.withAlphaComponent(0.80), y: h - 486)
    // Sat on the baseline of the card rather than under the tagline, so the
    // two do not read as three lines of one paragraph.
    draw("memoe.app", 26, .regular, brandCream.withAlphaComponent(0.45), y: 58, box: 40)
    img.unlockFocus()
    return img
}

// ---- Chrome Web Store -------------------------------------------------------
// `swift scripts/make-icon.swift webstore <out-dir> [pane.png]` writes only the
// store's pictures, into a directory the caller names (normally
// dist/chrome-webstore/, which is gitignored), and touches nothing committed:
//
//   icon-{16,32,48,128}.png     the extension's own icons, which go in the zip
//   promo-tile-440x280.png      the store's small promo tile
//   screenshot-1280x800.png     only when a pane picture is passed: the
//                               Chrome row's detail pane from `Moe
//                               --settings-snapshot`, recut onto a 1280x800
//                               card with a caption (see storeScreenshot)
//
// The 128 follows the store's rule for it: 96x96 of artwork centred in 16 px
// of transparent margin, because the store draws its own frame around it. The
// tile and screenshot are written without an alpha channel, which is what the
// store asks for.

/// A PNG with no alpha channel — the store's tile and screenshots.
func opaquePNG(_ img: NSImage) -> Data {
    // An RGB bitmap with no alpha has to be a 32-bit "skip" context: Core
    // Graphics will not draw into a packed 24-bit one (it traps).
    let w = Int(img.size.width), h = Int(img.size.height)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    brandBlack.set(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("png encode failed") }
    return data as Data
}

func storeIcon128() -> NSImage {
    let img = NSImage(size: NSSize(width: 128, height: 128))
    img.lockFocus()
    NSColor.clear.set(); NSRect(x: 0, y: 0, width: 128, height: 128).fill()
    render(size: 96, tight: true).draw(in: NSRect(x: 16, y: 16, width: 96, height: 96))
    img.unlockFocus()
    return img
}

func cardText(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
              in r: NSRect, centred: Bool = false) {
    let para = NSMutableParagraphStyle(); para.lineSpacing = 4
    if centred { para.alignment = .center }
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: color, .paragraphStyle: para]
    NSAttributedString(string: text, attributes: a).draw(in: r)
}

func promoTile() -> NSImage {
    let w: CGFloat = 440, h: CGFloat = 280
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSGradient(starting: rgb(0x14141a), ending: brandBlack)!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    render(size: 150).draw(in: NSRect(x: 28, y: h / 2 - 75, width: 150, height: 150))
    cardText("Memoe", 44, .bold, brandCream, in: NSRect(x: 190, y: 138, width: 240, height: 60))
    cardText("Moe works in a tab group\nof its own in your Chrome.", 18, .regular,
             brandCream.withAlphaComponent(0.80), in: NSRect(x: 192, y: 78, width: 240, height: 60))
    cardText("memoe.app", 13, .regular, brandCream.withAlphaComponent(0.45),
             in: NSRect(x: 192, y: 22, width: 200, height: 20))
    img.unlockFocus()
    return img
}

/// The store screenshot: the real "Moe in your Chrome" detail pane, cut out of
/// `Moe --settings-snapshot`'s `main-connections-chrome-connected-dark.png`.
///
/// Only the detail pane's own words and its Turn off button are used, not the
/// whole window. The snapshot runs against an empty scratch home, so its
/// sidebar shows the brain "Starting…" and the Mac apps "Not installed", which
/// is not what a person sees; and both the sidebar row and the pane header draw
/// a Chrome-coloured mark, which a store listing must not (it reads as Google's
/// endorsement). The header is redrawn here with Memoe's own mark.
///
/// The cut rectangles are pixels of that 1680x1120 picture (the 840x560 pane
/// at 2x), measured on 2026-09-24, top-left origin: the detail column starts at
/// x 602; "What it does" through the last line of the explanation is y 180-400;
/// the Turn off button is x 640-830, y 995-1085. A pane of any other size is
/// refused rather than cut in the wrong place.
func storeScreenshot(pane: NSImage) -> NSImage {
    var r = NSRect(origin: .zero, size: pane.size)
    guard let cg = pane.cgImage(forProposedRect: &r, context: nil, hints: nil),
          cg.width == 1680, cg.height == 1120 else {
        FileHandle.standardError.write("webstore: the pane must be the 1680x1120 main-connections-chrome-connected-dark.png\n".data(using: .utf8)!)
        exit(1)
    }
    let words = cg.cropping(to: CGRect(x: 640, y: 180, width: 1000, height: 220))!
    let button = cg.cropping(to: CGRect(x: 640, y: 995, width: 190, height: 90))!
    // The panel is filled with a stretch of the pane's own empty background
    // (y 450-950 has nothing on it) and the dot with the pane's own dot, both
    // drawn as image, so they go through the same colour conversion as the
    // cut-outs beside them. A colour read off the bitmap and filled did not
    // match: the seam showed.
    let paneBG = cg.cropping(to: CGRect(x: 1100, y: 500, width: 400, height: 400))!
    let greenDot = cg.cropping(to: CGRect(x: 778, y: 118, width: 16, height: 16))!

    let w: CGFloat = 1280, h: CGFloat = 800
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    NSGradient(starting: rgb(0x14141a), ending: brandBlack)!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    cardText("Moe works in a tab group of its own in your Chrome — never in your tabs.",
             28, .semibold, brandCream, in: NSRect(x: 40, y: h - 76, width: w - 80, height: 44), centred: true)

    let panel = NSRect(x: 150, y: 60, width: 980, height: 620)
    let clip = NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.6).cgColor)
    NSColor(white: 0.1, alpha: 1).set(); clip.fill()
    ctx.restoreGState()
    ctx.saveGState(); clip.addClip(); ctx.draw(paneBG, in: panel); ctx.restoreGState()

    // Header: Memoe's mark, the row's name, and its state.
    let mark: CGFloat = 96
    render(size: 128).draw(in: NSRect(x: panel.minX + 40, y: panel.maxY - 40 - mark, width: mark, height: mark))
    cardText("Moe in your Chrome", 40, .semibold, brandCream,
             in: NSRect(x: panel.minX + 160, y: panel.maxY - 100, width: 700, height: 56))
    let dot = NSRect(x: panel.minX + 162, y: panel.maxY - 128, width: 14, height: 14)
    ctx.draw(greenDot, in: dot)
    cardText("Connected", 24, .medium, brandCream,
             in: NSRect(x: panel.minX + 186, y: panel.maxY - 138, width: 300, height: 34))

    // The pane's own words and button, at 0.9 of their 2x size.
    NSGraphicsContext.current?.imageInterpolation = .high
    let k: CGFloat = 0.9
    let wr = NSRect(x: panel.minX + 40, y: panel.maxY - 190 - 220 * k, width: 1000 * k, height: 220 * k)
    ctx.draw(words, in: wr)
    ctx.draw(button, in: NSRect(x: panel.minX + 40, y: panel.minY + 36, width: 190 * k, height: 90 * k))
    img.unlockFocus()
    return img
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "webstore" {
    let out = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
    try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for sz in [16, 32, 48] {
        write(render(size: sz, tight: true), to: "\(out)/icon-\(sz).png")
    }
    write(storeIcon128(), to: "\(out)/icon-128.png")
    try! opaquePNG(promoTile()).write(to: URL(fileURLWithPath: "\(out)/promo-tile-440x280.png"))
    var wrote = ["icon-{16,32,48,128}.png", "promo-tile-440x280.png"]
    if CommandLine.arguments.count > 3 {
        guard let pane = NSImage(contentsOfFile: CommandLine.arguments[3]) else {
            FileHandle.standardError.write("cannot read \(CommandLine.arguments[3])\n".data(using: .utf8)!)
            exit(1)
        }
        try! opaquePNG(storeScreenshot(pane: pane))
            .write(to: URL(fileURLWithPath: "\(out)/screenshot-1280x800.png"))
        wrote.append("screenshot-1280x800.png")
    }
    print("wrote to \(out): " + wrote.joined(separator: ", "))
    exit(0)
}

// ---- Pipeline ---------------------------------------------------------------
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .deletingLastPathComponent().path
fm.changeCurrentDirectoryPath(root)
try! fm.createDirectory(atPath: "scratch", withIntermediateDirectories: true)
let iconset = "Resources/Moe.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

write(render(size: 1024), to: "scratch/icon-1024.png")
for base in [16, 32, 128, 256, 512] {
    write(render(size: base), to: "\(iconset)/icon_\(base)x\(base).png")
    write(render(size: base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
write(render(size: 512), to: "Resources/icon-preview.png")
write(sheet(sizes: [64, 32, 16]), to: "Resources/icon-preview-small.png")
for sz in [16, 32, 180, 512] {
    write(render(size: sz, tight: true), to: "site/assets/icon-\(sz).png")
}
// The three sizes an ICO carries, drawn at their real size rather than
// downscaled from a big one: a stroke this thin goes to mush when resampled.
// scripts/make-favicon.py packs them; they are not linked from any page, so
// they live in scratch/ rather than site/assets/.
try! fm.createDirectory(atPath: "scratch/favicon", withIntermediateDirectories: true)
for sz in [16, 32, 48] {
    write(render(size: sz, tight: true), to: "scratch/favicon/\(sz).png")
}
write(render(size: 120, opaque: true), to: "site/assets/moe-logo-120.png")
write(render(size: 512, opaque: true), to: "site/assets/moe-logo-512.png")
write(ogImage(), to: "site/assets/og.png")

// `Resources/Moe.icns` is committed and is what build.sh copies into the
// bundle, so it is rebuilt here rather than left for someone to remember.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", "Resources/Moe.icns", iconset]
try! iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed — Resources/Moe.icns not rebuilt\n".data(using: .utf8)!)
    exit(1)
}

print("""
wrote
  Resources/Moe.icns + Moe.iconset/ (10 files)
  Resources/icon-preview.png, icon-preview-small.png
  site/assets/icon-{16,32,180,512}.png
  site/assets/moe-logo-{120,512}.png
  site/assets/og.png
  scratch/icon-1024.png
next: python3 scripts/make-favicon.py   (site/favicon.ico)
""")
