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
    // Glass, painted.
    //
    // Real glass — the material macOS applies itself, that refracts the desktop
    // behind it and changes as the wallpaper does — needs the `.icon` format
    // from Icon Composer. This is the other kind: a picture of glass, drawn
    // once. It cannot bend anything behind it, so everything that says "glass"
    // has to be inside the tile: a lit top edge, a body that fades from bright
    // to dim, a shine across the upper half, and a floor of colour that reads
    // as something seen through.
    //
    // The tile is ours rather than absent on purpose. macOS supplies its own
    // light tile behind an icon that has none — measured: our transparent
    // source came back composited onto a white squircle — so "no tile" is not
    // a thing a classic `.icns` can express, and painting one is the only way
    // to decide what it looks like.
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    let shape = squircle(full)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // What the glass is over. Dark, so a light mark reads on it whatever the
    // wallpaper is doing — the tile is the contrast the mark cannot get from
    // the Dock.
    let ground = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [rgb(46, 72, 104), rgb(18, 24, 36)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.4, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A wash of colour low in the tile: the thing being looked through at.
    let wash = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(64, 200, 130, 0.34), rgb(64, 200, 130, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(wash, startCenter: CGPoint(x: s * 0.30, y: s * 0.24), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.30, y: s * 0.24), endRadius: s * 0.62,
                           options: [])

    // The body of the glass: brighter where the light enters.
    let body = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0.04)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.15),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The shine: a soft band across the upper half, cut by the tile's own
    // shape so it behaves like a surface rather than a decal.
    ctx.saveGState()
    let shine = CGMutablePath()
    shine.move(to: CGPoint(x: 0, y: s * 0.62))
    shine.addCurve(to: CGPoint(x: s, y: s * 0.78),
                   control1: CGPoint(x: s * 0.35, y: s * 0.86),
                   control2: CGPoint(x: s * 0.62, y: s * 0.62))
    shine.addLine(to: CGPoint(x: s, y: s))
    shine.addLine(to: CGPoint(x: 0, y: s))
    shine.closeSubpath()
    ctx.addPath(shine); ctx.clip()
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(255, 255, 255, 0.26), rgb(255, 255, 255, 0.02)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.60),
                           options: [])
    ctx.restoreGState()

    // The mark, under the glass rather than on it: a shadow away from the light.
    let stroke = s * 0.115
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

    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.035,
                  color: rgb(0, 0, 0, 0.40))
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.addPath(u)
    ctx.setStrokeColor(rgb(246, 250, 254))
    ctx.strokePath()

    let bar = CGRect(x: left - stroke / 2, y: s * 0.650,
                     width: right - left + stroke, height: stroke * 0.86)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: stroke * 0.43,
                       cornerHeight: stroke * 0.43, transform: nil))
    ctx.setFillColor(rgb(64, 200, 130))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.restoreGState()

    // The lit edge. Brighter along the top, fading down the sides — a lens has
    // one, and it is the single cue that says "thick" rather than "printed".
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.setLineWidth(s * 0.016)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.62))
    ctx.addPath(squircle(full.insetBy(dx: s * 0.008, dy: s * 0.008)))
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
