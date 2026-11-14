// Draws the MacAuth app icon (1024 x 1024 PNG): macOS icon square, blue-violet gradient, white shield
// with six dots (a code, suggested). Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Aufruf: make-icon.swift <ausgabe.png>\n".utf8))
    exit(2)
}
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// macOS icon grid: 824 pt square on the 1024 canvas, corner radius about 22.4 %.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(10, 5, 60, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(color(60, 40, 200))
ctx.fillPath()
ctx.restoreGState()

// Gradient: bright blue (top left) to deep violet (bottom right).
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space,
                          colors: [color(64, 132, 255), color(98, 70, 235), color(88, 38, 200)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX + 60, y: tile.maxY), end: CGPoint(x: tile.maxX - 60, y: tile.minY), options: [])
// Gentle top highlight.
let gloss = CGGradient(colorsSpace: space, colors: [color(255, 255, 255, 0.20), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.midY + 80), options: [])
ctx.restoreGState()

// Shield, centred a little above the middle.
let cx: CGFloat = 512
let cy: CGFloat = 520
let halfWidth: CGFloat = 215
let top: CGFloat = cy + 255
let shoulder: CGFloat = cy + 185
let sideBottom: CGFloat = cy - 30
let tip: CGFloat = cy - 275
let shield = CGMutablePath()
shield.move(to: CGPoint(x: cx, y: top))
shield.addCurve(to: CGPoint(x: cx + halfWidth, y: shoulder),
                control1: CGPoint(x: cx + 80, y: top - 10), control2: CGPoint(x: cx + 150, y: shoulder + 20))
shield.addLine(to: CGPoint(x: cx + halfWidth, y: sideBottom))
shield.addCurve(to: CGPoint(x: cx, y: tip),
                control1: CGPoint(x: cx + halfWidth, y: sideBottom - 120), control2: CGPoint(x: cx + 100, y: tip + 60))
shield.addCurve(to: CGPoint(x: cx - halfWidth, y: sideBottom),
                control1: CGPoint(x: cx - 100, y: tip + 60), control2: CGPoint(x: cx - halfWidth, y: sideBottom - 120))
shield.addLine(to: CGPoint(x: cx - halfWidth, y: shoulder))
shield.addCurve(to: CGPoint(x: cx, y: top),
                control1: CGPoint(x: cx - 150, y: shoulder + 20), control2: CGPoint(x: cx - 80, y: top - 10))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(20, 10, 90, 0.35))
ctx.addPath(shield)
ctx.setFillColor(color(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

// Six dots (3 x 2), as in "482 913", cut out in the icon's violet.
let dotRadius: CGFloat = 31
let pitch: CGFloat = 92
ctx.setFillColor(color(86, 60, 220))
for row in 0..<2 {
    for col in 0..<3 {
        let x = cx + CGFloat(col - 1) * pitch
        let y = cy + 20 - CGFloat(row) * pitch + pitch / 2 - 20
        ctx.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    }
}

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
