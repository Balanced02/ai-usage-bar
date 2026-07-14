import SwiftUI
import AppKit

// Renders the DMG window background: branded title + a "drag to Applications"
// swoosh arrow between the app icon (left) and the Applications folder (right).
// Writes a multi-representation TIFF (540×380 @1x + 1080×760 @2x in one file) so
// Finder shows it crisp on both retina and non-retina — create-dmg has no @2x
// support, but Finder resolves the right rep from the TIFF. Also writes a PNG
// preview next to it for docs.
//   dmgbggen <out.tiff>
//
// Must match Scripts/release create-dmg geometry: window 540×380, app icon at
// (140,190), Applications drop-link at (400,190) — measured from the top-left.

private let W: CGFloat = 540
private let H: CGFloat = 380

struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.99, green: 0.99, blue: 1.0),
                                    Color(red: 0.93, green: 0.92, blue: 0.97)],
                           startPoint: .top, endPoint: .bottom)

            // Title + tagline (top, clear of the y=190 icon row).
            VStack(spacing: 5) {
                Text("AI Usage Bar")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Color(red: 0.13, green: 0.14, blue: 0.20))
                Text("Every AI-coding limit, in your menu bar")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.48))
            }
            .position(x: W / 2, y: 52)

            // The swoosh arrow from the app icon toward Applications (icons drawn
            // by Finder at x=140 and x=400; keep clear of their ~64px radius).
            SwooshArrow()
                .stroke(Color(red: 0.55, green: 0.48, blue: 0.95),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .shadow(color: Color(red: 0.55, green: 0.48, blue: 0.95).opacity(0.25), radius: 4, y: 2)

            Text("Drag to Applications")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.48, blue: 0.95))
                .position(x: W / 2, y: 250)

            // Faint hint labels under the two icon slots (Finder also draws the
            // real icon labels here; this just anchors the eye).
        }
        .frame(width: W, height: H)
    }
}

/// A curved arrow (quadratic swoosh) from ~(205,190) to ~(338,190) with a head.
struct SwooshArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: 208, y: 188)
        let end = CGPoint(x: 336, y: 190)
        let control = CGPoint(x: 272, y: 232)   // dips down for a swoosh
        p.move(to: start)
        p.addQuadCurve(to: end, control: control)
        // Arrowhead at `end`, pointing up-right along the tangent.
        let a1 = CGPoint(x: end.x - 15, y: end.y - 2)
        let a2 = CGPoint(x: end.x - 4, y: end.y + 13)
        p.move(to: a1); p.addLine(to: end); p.addLine(to: a2)
        return p
    }
}

@MainActor
func rep(scale: CGFloat) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: DMGBackground())
    renderer.scale = scale
    guard let cg = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: W, height: H)   // point size; pixels = W*scale → tags the DPI
    return rep
}

@MainActor
func render() {
    let out = CommandLine.arguments.dropFirst().first ?? "dmg-background.tiff"
    guard let r1 = rep(scale: 1), let r2 = rep(scale: 2) else {
        print("dmgbggen: render failed"); return
    }
    // Multi-rep TIFF: Finder picks the 2x rep on retina, the 1x elsewhere.
    let image = NSImage(size: NSSize(width: W, height: H))
    image.addRepresentation(r1)
    image.addRepresentation(r2)
    if let tiff = image.tiffRepresentation {
        try? tiff.write(to: URL(fileURLWithPath: out))
        print("dmgbggen: wrote \(out) (1x + 2x)")
    }
    // PNG preview (the 2x rep) for docs.
    if let png = r2.representation(using: .png, properties: [:]) {
        let preview = (out as NSString).deletingPathExtension + ".png"
        try? png.write(to: URL(fileURLWithPath: preview))
        print("dmgbggen: wrote \(preview)")
    }
}

render()
