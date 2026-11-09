// Renders the app icon procedurally (original artwork, no game assets).
// Usage: swift Tools/make_icon.swift [output.png] [variant: aurora|ember]
// Glossy isometric gem cubes on an aurora sky; two matching cubes touch and burst into a sparkle.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "Resources/AppIcon.png"
let variant = args.count > 2 ? args[2] : "aurora"
let S: CGFloat = 1024

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// top-left origin, y down
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

func C(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
}
var rng = SystemRandomNumberGenerator()
struct LCG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF) } }
var rnd = LCG(s: 20261109)

// ---------------------------------------------------------------- squircle body
let inset: CGFloat = 100, body = S - 2 * inset
func squircle(_ rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath(); let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}
let bodyRect = CGRect(x: inset, y: inset, width: body, height: body)
let bodyPath = squircle(bodyRect)

// drop shadow of the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: C(0, 0, 0, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(C(0.05, 0.03, 0.12)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()

let palette: (top: CGColor, bottom: CGColor, glowA: (CGFloat, CGFloat, CGFloat), glowB: (CGFloat, CGFloat, CGFloat))
if variant == "ember" {
    palette = (C(0.30, 0.06, 0.16), C(0.04, 0.01, 0.05), (1.0, 0.45, 0.20), (0.95, 0.20, 0.55))
} else {
    palette = (C(0.13, 0.07, 0.33), C(0.015, 0.01, 0.06), (0.10, 0.95, 0.75), (0.80, 0.25, 1.0))
}
ctx.drawLinearGradient(grad([palette.top, palette.bottom]), start: CGPoint(x: 512, y: inset), end: CGPoint(x: 512, y: S - inset), options: [])

// soft nebula glows
func glow(_ c: CGPoint, _ r: CGFloat, _ col: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) {
    ctx.drawRadialGradient(grad([C(col.0, col.1, col.2, a), C(col.0, col.1, col.2, 0)]),
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
glow(CGPoint(x: 260, y: 250), 420, palette.glowA, 0.30)
glow(CGPoint(x: 820, y: 330), 380, palette.glowB, 0.28)
glow(CGPoint(x: 520, y: 900), 420, palette.glowB, 0.18)

// aurora curtains: many thin vertical ray strips following a wavy band
ctx.setBlendMode(.screen)
for band in 0..<2 {
    let fb = CGFloat(band)
    var x: CGFloat = inset
    while x < S - inset {
        let u = (x - inset) / body
        let y0 = 230 + fb * 120 + 70 * sin(u * 5.2 + fb * 1.7) + 30 * sin(u * 13.0 + fb)
        let h = 150 + 90 * sin(u * 7.0 + fb * 2.3) + 80 * rnd.next()
        let k = 0.5 + 0.5 * rnd.next()
        let t = min(1, max(0, u * 0.9 + fb * 0.35))
        let r = palette.glowA.0 * (1 - t) + palette.glowB.0 * t
        let g = palette.glowA.1 * (1 - t) + palette.glowB.1 * t
        let b = palette.glowA.2 * (1 - t) + palette.glowB.2 * t
        let a = 0.16 * k
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: y0 - h, width: 3.2, height: h * 1.25))
        ctx.drawLinearGradient(grad([C(r, g, b, 0), C(r, g, b, a), C(r, g, b, a * 1.6), C(r, g, b, 0)], [0, 0.55, 0.8, 1]),
                               start: CGPoint(x: x, y: y0 - h), end: CGPoint(x: x, y: y0 + h * 0.25), options: [])
        ctx.restoreGState()
        x += 3
    }
}
// stars
for _ in 0..<70 {
    let p = CGPoint(x: inset + rnd.next() * body, y: inset + rnd.next() * body * 0.75)
    let r = 0.8 + rnd.next() * 2.2
    glow(p, r * 3, (0.8, 0.85, 1.0), 0.5 * rnd.next() + 0.2)
}
ctx.setBlendMode(.normal)

// ---------------------------------------------------------------- isometric cubes
let s: CGFloat = 200
let cos30: CGFloat = 0.8660254
let origin = CGPoint(x: 512 - 0.5 * cos30 * s, y: 575)
func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
    CGPoint(x: origin.x + (x - y) * cos30 * s, y: origin.y + (x + y) * 0.5 * s - z * s)
}
func poly(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
func shrink(_ pts: [CGPoint], _ k: CGFloat) -> [CGPoint] {
    let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    return pts.map { lerp(c, $0, k) }
}

// contact shadow on the "floor"
ctx.saveGState()
ctx.translateBy(x: P(1, 0.5, 0).x, y: P(1, 0.5, 0).y + 40)
ctx.scaleBy(x: 1, y: 0.42)
ctx.drawRadialGradient(grad([C(0, 0, 0, 0.6), C(0, 0, 0, 0)]), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 420, options: [])
ctx.restoreGState()

struct Gem { var base: (CGFloat, CGFloat, CGFloat); var stone: Bool }
func shade(_ c: (CGFloat, CGFloat, CGFloat), _ k: CGFloat, _ a: CGFloat = 1) -> CGColor {
    C(min(1, c.0 * k), min(1, c.1 * k), min(1, c.2 * k), a)
}
func mixW(_ c: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    (c.0 + (1 - c.0) * t, c.1 + (1 - c.1) * t, c.2 + (1 - c.2) * t)
}

func drawFace(_ pts: [CGPoint], gem: Gem, light: CGFloat, gStart: CGPoint, gEnd: CGPoint) {
    let path = poly(pts)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let c = gem.base
    ctx.drawLinearGradient(grad([shade(mixW(c, 0.25 * light), 0.75 + 0.45 * light), shade(c, 0.35 + 0.45 * light)]),
                           start: gStart, end: gEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // inner facet
    let inner = shrink(pts, gem.stone ? 0.74 : 0.62)
    if gem.stone {
        // chiselled panel: dark groove + light lip
        ctx.addPath(poly(inner)); ctx.setStrokeColor(shade(c, 0.35, 0.9)); ctx.setLineWidth(7); ctx.strokePath()
        ctx.addPath(poly(shrink(pts, 0.70))); ctx.setStrokeColor(shade(mixW(c, 0.4), 1.1, 0.35)); ctx.setLineWidth(3); ctx.strokePath()
    } else {
        // bevels from outer corners to facet corners
        for i in 0..<4 {
            let q = poly([pts[i], pts[(i + 1) % 4], inner[(i + 1) % 4], inner[i]])
            let k: CGFloat = [1.25, 0.8, 0.6, 1.05][i]
            ctx.addPath(q); ctx.setFillColor(shade(mixW(c, 0.15 * light), (0.55 + 0.45 * light) * k, 0.55)); ctx.fillPath()
        }
        ctx.saveGState(); ctx.addPath(poly(inner)); ctx.clip()
        ctx.drawLinearGradient(grad([shade(mixW(c, 0.55 * light), 1.15), shade(c, 0.55 + 0.4 * light)]),
                               start: gStart, end: gEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        ctx.addPath(poly(inner)); ctx.setStrokeColor(C(1, 1, 1, 0.35 * light + 0.1)); ctx.setLineWidth(2.5); ctx.strokePath()
    }
    ctx.restoreGState()
    // crisp edges
    ctx.addPath(path); ctx.setStrokeColor(shade(c, 0.25, 0.9)); ctx.setLineWidth(3); ctx.setLineJoin(.round); ctx.strokePath()
}

func drawCube(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ gem: Gem) {
    // corners
    let t0 = P(x, y, z + 1), t1 = P(x + 1, y, z + 1), t2 = P(x + 1, y + 1, z + 1), t3 = P(x, y + 1, z + 1)
    let b1 = P(x + 1, y, z), b2 = P(x + 1, y + 1, z), b3 = P(x, y + 1, z)
    // emissive glow behind gem cubes
    if !gem.stone {
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        let c = P(x + 0.5, y + 0.5, z + 0.5)
        glow(c, s * 1.05, gem.base, 0.28)
        ctx.restoreGState()
    }
    drawFace([t3, t2, b2, b3], gem: gem, light: 0.65, gStart: t3, gEnd: b2)          // front-left (y+)
    drawFace([t2, t1, b1, b2], gem: gem, light: 0.38, gStart: t1, gEnd: b2)          // front-right (x+)
    drawFace([t0, t1, t2, t3], gem: gem, light: 1.0, gStart: t0, gEnd: t2)           // top
    // glossy sweep on the top face
    ctx.saveGState(); ctx.addPath(poly([t0, t1, t2, t3])); ctx.clip()
    let a = lerp(t0, t3, 0.15), b = lerp(t1, t2, 0.15)
    ctx.setBlendMode(.screen)
    ctx.drawLinearGradient(grad([C(1, 1, 1, 0), C(1, 1, 1, gem.stone ? 0.15 : 0.45), C(1, 1, 1, 0)], [0, 0.5, 1]),
                           start: lerp(a, b, 0.0), end: lerp(lerp(t0, t3, 0.6), lerp(t1, t2, 0.6), 0.4), options: [])
    ctx.restoreGState()
    // highlight on the top front edge
    ctx.move(to: t3); ctx.addLine(to: t2); ctx.addLine(to: t1)
    ctx.setStrokeColor(C(1, 1, 1, gem.stone ? 0.35 : 0.8)); ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.strokePath()
    ctx.move(to: t2); ctx.addLine(to: b2)
    ctx.setStrokeColor(C(1, 1, 1, gem.stone ? 0.18 : 0.45)); ctx.setLineWidth(3); ctx.strokePath()
}

let stone = Gem(base: (0.55, 0.56, 0.66), stone: true)
let cyan = variant == "ember" ? Gem(base: (1.0, 0.55, 0.12), stone: false) : Gem(base: (0.10, 0.92, 0.80), stone: false)
let magenta = Gem(base: (0.92, 0.25, 0.85), stone: false)

drawCube(0, 0, 0, stone)
drawCube(1, 0, 0, cyan)
drawCube(0, 0, 1, magenta)
drawCube(1, 0, 1, cyan)

// sparkle burst where the two matching cubes meet
func sparkle(_ c: CGPoint, _ len: CGFloat, _ k: CGFloat) {
    ctx.saveGState(); ctx.setBlendMode(.screen)
    glow(c, len * 0.9, (1.0, 1.0, 0.95), 0.75 * k)
    glow(c, len * 1.8, cyan.base, 0.45 * k)
    for (ang, l) in [(0.0, 1.0), (CGFloat.pi / 2, 1.0), (CGFloat.pi / 4, 0.45), (3 * CGFloat.pi / 4, 0.45)] {
        let d = CGPoint(x: cos(ang), y: sin(ang)), n = CGPoint(x: -d.y, y: d.x)
        let w = len * 0.07 * (l > 0.5 ? 1 : 0.7)
        let L = len * l
        let ray = poly([CGPoint(x: c.x - d.x * L, y: c.y - d.y * L), CGPoint(x: c.x + n.x * w, y: c.y + n.y * w),
                        CGPoint(x: c.x + d.x * L, y: c.y + d.y * L), CGPoint(x: c.x - n.x * w, y: c.y - n.y * w)])
        ctx.addPath(ray); ctx.setFillColor(C(1, 1, 0.97, 0.95 * k)); ctx.fillPath()
    }
    ctx.restoreGState()
}
sparkle(P(2, 1, 1), 150, 1.0)
sparkle(lerp(P(1, 1, 1), P(2, 1, 1), 0.25), 46, 0.7)
sparkle(P(0.35, 0, 2.05), 40, 0.6)
// little shards flying out of the match
ctx.saveGState(); ctx.setBlendMode(.screen)
for i in 0..<9 {
    let ang = -CGFloat.pi * 0.15 + CGFloat(i) / 8 * CGFloat.pi * 0.9 - 0.35
    let dist = 150 + 70 * rnd.next()
    let c0 = P(2, 1, 1)
    let p = CGPoint(x: c0.x + cos(ang) * dist, y: c0.y - sin(ang) * dist * 0.9)
    glow(p, 10 + 9 * rnd.next(), i % 2 == 0 ? cyan.base : (1, 1, 1), 0.9)
}
ctx.restoreGState()

// ---------------------------------------------------------------- finish: vignette + rim light
ctx.drawRadialGradient(grad([C(0, 0, 0, 0), C(0, 0, 0, 0.35)]), startCenter: CGPoint(x: 512, y: 470), startRadius: 250,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 600, options: [.drawsAfterEndLocation])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(squircle(bodyRect.insetBy(dx: 1.5, dy: 1.5)))
ctx.setLineWidth(3)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(grad([C(1, 1, 1, 0.45), C(1, 1, 1, 0.05), C(1, 1, 1, 0.12)], [0, 0.5, 1]),
                       start: CGPoint(x: 512, y: inset), end: CGPoint(x: 512, y: S - inset), options: [])
ctx.restoreGState()

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
