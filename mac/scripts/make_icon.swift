// Draws the 1024×1024 app icon: night sky over the earth's glow, with a folder and a sparkle.
// Usage: swift make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt rounded square centered on a 1024 canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = tile.width * 0.225
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(color(0x071430)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()

// Sky
let sky = CGGradient(colorsSpace: space, colors: [color(0x0d2a5c), color(0x071430), color(0x02040b)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

// Earth glow along the bottom
let glow = CGGradient(colorsSpace: space, colors: [color(0xe9f3ff, 0.95), color(0x9cc8f5, 0.75), color(0x3f7fc4, 0.45), color(0x173c73, 0)] as CFArray,
                      locations: [0, 0.2, 0.45, 1])!
ctx.saveGState()
ctx.translateBy(x: size * 0.5, y: tile.minY - 250)
ctx.scaleBy(x: 1.6, y: 1)
ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 560, options: [])
ctx.restoreGState()

// Stars
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<70 {
    let x = tile.minX + rnd() * tile.width, y = tile.minY + tile.height * (0.42 + rnd() * 0.58)
    let r = 1.5 + rnd() * 3.5
    ctx.setFillColor(color(0xdbe8ff, 0.35 + rnd() * 0.6))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Folder
let fw: CGFloat = 470, fh: CGFloat = 340
let fx = (size - fw) / 2, fy: CGFloat = 330
let back = CGMutablePath()
back.addRoundedRect(in: CGRect(x: fx, y: fy, width: fw, height: fh), cornerWidth: 34, cornerHeight: 34)
back.addRoundedRect(in: CGRect(x: fx, y: fy + fh - 40, width: fw * 0.42, height: 82), cornerWidth: 26, cornerHeight: 26)
ctx.setFillColor(color(0x4a8fe0)); ctx.addPath(back); ctx.fillPath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x02122e, 0.5))
let front = CGPath(roundedRect: CGRect(x: fx, y: fy, width: fw, height: fh - 48), cornerWidth: 34, cornerHeight: 34, transform: nil)
let frontGrad = CGGradient(colorsSpace: space, colors: [color(0x8fc2ff), color(0x5aa9ff)] as CFArray, locations: [0, 1])!
ctx.addPath(front); ctx.clip()
ctx.drawLinearGradient(frontGrad, start: CGPoint(x: 0, y: fy + fh), end: CGPoint(x: 0, y: fy), options: [])
ctx.restoreGState()

// Sparkle (four-point star) over the folder's corner
func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat, alpha: CGFloat) {
    let p = CGMutablePath()
    let w = r * 0.28
    p.move(to: CGPoint(x: cx, y: cy + r))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + w, y: cy + w))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx + w, y: cy - w))
    p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - w, y: cy - w))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx - w, y: cy + w))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xffffff, 0.8))
    ctx.setFillColor(color(0xffffff, alpha)); ctx.addPath(p); ctx.fillPath()
    ctx.restoreGState()
}
sparkle(cx: fx + fw - 10, cy: fy + fh + 40, r: 92, alpha: 1)
sparkle(cx: fx + fw - 128, cy: fy + fh + 128, r: 38, alpha: 0.9)

ctx.restoreGState()

// Thin inner highlight on the tile edge
ctx.addPath(tilePath); ctx.setStrokeColor(color(0xffffff, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
