import AppKit
import Foundation

// uDeck's application icon, drawn rather than stored.
//
// A .icns is a binary nobody can review and nobody can adjust without the file
// it came from — so the file it comes from is this, and `Scripts/make-icon.sh`
// turns it into the icon. Changing the colour or the weight of the letter is a
// line here and a re-run, not a round trip through an image editor.
//
// The mark is ū: the first letter of the name and the bar the panel hangs from,
// which happen to be the same shape. The bar is the green the island's own
// indicator uses for "everything is fine" — the only colour in the icon, and it
// is the application's, not a decoration.

let out = CommandLine.arguments[1]

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
}

func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.width * 0.2237, transform: nil)
}

func draw(_ ctx: CGContext, _ s: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    let shape = squircle(full)

    // A lit slate rather than a flat one: macOS icons are objects with a light
    // source, and a plain fill reads as a placeholder next to them.
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(52, 59, 70), rgb(22, 25, 31)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.35, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The glow under the bar: the panel is a lit thing at the top of a screen.
    let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(92, 200, 140, 0.34), rgb(92, 200, 140, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: s * 0.5, y: s * 0.70), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.70), endRadius: s * 0.52,
                           options: [])

    let stroke = s * 0.115
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)

    let left = s * 0.315, right = s * 0.685
    let top = s * 0.555, bottom = s * 0.295
    let u = CGMutablePath()
    u.move(to: CGPoint(x: left, y: top))
    u.addLine(to: CGPoint(x: left, y: bottom + s * 0.055))
    u.addArc(tangent1End: CGPoint(x: left, y: bottom),
             tangent2End: CGPoint(x: s * 0.5, y: bottom), radius: s * 0.10)
    u.addArc(tangent1End: CGPoint(x: right, y: bottom),
             tangent2End: CGPoint(x: right, y: top), radius: s * 0.10)
    u.addLine(to: CGPoint(x: right, y: top))

    // The letter sits on the tile rather than in it: a shadow under it and a
    // hairline over it, which is what makes a shape look printed on glass.
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.03,
                  color: rgb(0, 0, 0, 0.45))
    ctx.addPath(u)
    ctx.setStrokeColor(rgb(240, 245, 250))
    ctx.strokePath()

    let bar = CGRect(x: left - stroke / 2, y: s * 0.650,
                     width: right - left + stroke, height: stroke * 0.86)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: stroke * 0.43,
                       cornerHeight: stroke * 0.43, transform: nil))
    ctx.setFillColor(rgb(92, 200, 140))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // The bright top edge every macOS icon carries.
    ctx.setLineWidth(s * 0.012)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.5))
    ctx.addPath(squircle(full.insetBy(dx: s * 0.006, dy: s * 0.006)))
    ctx.strokePath()
    ctx.restoreGState()
}

for size in [16, 32, 64, 128, 256, 512, 1024] as [CGFloat] {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, size)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(px).png"))
}
print("rendered 7 sizes into \(out)")
