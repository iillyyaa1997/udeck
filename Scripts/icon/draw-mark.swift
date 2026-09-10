import CoreGraphics
import Foundation

// The two shapes the application icon is made of, written out as SVG.
//
// The icon itself is an Icon Composer document — `Sources/uDeck/Support/uDeck.icon`
// — and macOS draws the glass: the tile, its thickness, the light along the top
// edge, the shadow under the mark. What the document has to supply is the mark,
// and it wants it as SVG. This file is where that shape lives, so the letter is
// still described exactly once, in code, and adjusting its weight or its
// proportions is a line here and a re-run of `Scripts/make-icon.sh`.
//
// The mark is ū: the first letter of the name and the bar the panel hangs from,
// which happen to be the same shape. The bar is the green the island's own
// indicator uses for "everything is fine" — the only colour we choose, and it is
// the application's, not a decoration.
//
// Everything is in fractions of the canvas, so the numbers below read the same
// at 16 points and at 1024.

let out = CommandLine.arguments[1]

let s: CGFloat = 1024
let stroke = s * 0.115
let left = s * 0.315, right = s * 0.685
let top = s * 0.555, bottom = s * 0.295

let ink = "#F6FAFE"
let green = "#40C882"

/// The letter, as the path a pen would take.
func letterPath() -> CGPath {
    let u = CGMutablePath()
    u.move(to: CGPoint(x: left, y: top))
    u.addLine(to: CGPoint(x: left, y: bottom + s * 0.055))
    u.addArc(tangent1End: CGPoint(x: left, y: bottom),
             tangent2End: CGPoint(x: s * 0.5, y: bottom), radius: s * 0.10)
    u.addArc(tangent1End: CGPoint(x: right, y: bottom),
             tangent2End: CGPoint(x: right, y: top), radius: s * 0.10)
    u.addLine(to: CGPoint(x: right, y: top))
    return u
}

// The stroke is turned into an outline rather than left as one.
//
// An SVG stroke survives a plain rendering, but the appearances macOS derives
// from the document — the dark one above all — rasterise it differently, and
// there the letter's counter filled in: ū stopped being a letter and became a
// blob. A filled path is the same shape by construction and is read the same way
// everywhere, so the pen stroke above is converted here, once, and the geometry
// is still stated only in the lines above.
func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    // CoreGraphics counts y upwards, SVG counts it down.
    func p(_ pt: CGPoint) -> String { "\(f(pt.x)) \(f(s - pt.y))" }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint:         d += "M \(p(e.points[0])) "
        case .addLineToPoint:      d += "L \(p(e.points[0])) "
        case .addQuadCurveToPoint: d += "Q \(p(e.points[0])) \(p(e.points[1])) "
        case .addCurveToPoint:     d += "C \(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2])) "
        case .closeSubpath:        d += "Z "
        @unknown default:          break
        }
    }
    return d.trimmingCharacters(in: .whitespaces)
}

func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(s))" height="\(Int(s))" viewBox="0 0 \(Int(s)) \(Int(s))">
      \(body)
    </svg>

    """
}

let outlined = letterPath().copy(strokingWithWidth: stroke, lineCap: .round,
                                 lineJoin: .round, miterLimit: 10)
let mark = svg("""
<path d="\(svgPathData(outlined))" fill="\(ink)" fill-rule="nonzero"/>
""")

// The bar sits above the letter and is as wide as the letter is, outer edge to
// outer edge — the same relationship the island has with the panel under it.
let barX = left - stroke / 2
let barW = right - left + stroke
let barY = s - (s * 0.650) - stroke * 0.86
let barH = stroke * 0.86
let bar = svg("""
<rect x="\(String(format: "%.2f", barX))" y="\(String(format: "%.2f", barY))" \
width="\(String(format: "%.2f", barW))" height="\(String(format: "%.2f", barH))" \
rx="\(String(format: "%.2f", stroke * 0.43))" ry="\(String(format: "%.2f", stroke * 0.43))" fill="\(green)"/>
""")

try mark.write(toFile: "\(out)/mark.svg", atomically: true, encoding: .utf8)
try bar.write(toFile: "\(out)/bar.svg", atomically: true, encoding: .utf8)
print("wrote mark.svg and bar.svg into \(out)")
