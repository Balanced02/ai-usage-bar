import SwiftUI
import AppKit

// Renders a 1024×1024 app icon PNG: a dark rounded tile with three usage meters.
//   icongen <output.png>

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.13, green: 0.14, blue: 0.20),
                             Color(red: 0.22, green: 0.24, blue: 0.34)],
                    startPoint: .top, endPoint: .bottom))

            VStack(spacing: 92) {
                bar(fill: 0.86, color: Color(red: 0.22, green: 0.80, blue: 0.45))  // green
                bar(fill: 0.60, color: Color(red: 0.98, green: 0.78, blue: 0.20))  // yellow
                bar(fill: 0.38, color: Color(red: 0.95, green: 0.45, blue: 0.22))  // orange
            }
            .padding(.horizontal, 190)
        }
        .frame(width: 1024, height: 1024)
    }

    private func bar(fill: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color).frame(width: geo.size.width * fill)
            }
        }
        .frame(height: 96)
    }
}

@MainActor
func render() async {
    let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("icongen: failed to render"); return
    }
    try? png.write(to: URL(fileURLWithPath: out))
    print("icongen: wrote \(out)")
}

await render()
