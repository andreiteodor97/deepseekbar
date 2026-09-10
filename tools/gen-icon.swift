import AppKit
import SwiftUI

/// Renders the app icon at every size macOS asks for.
///
/// The `AppIcon.appiconset` layout and `iconutil` are the only supported path to an
/// `.icns`, so this reads the sizes from the iconset directory it is given and writes
/// a PNG for each entry.
@main
struct IconRenderer {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            FileHandle.standardError.write(Data("usage: gen-icon <AppIcon.appiconset>\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: args[1])
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }

        guard !pngs.isEmpty else {
            FileHandle.standardError.write(Data("no PNG slots found in \(directory.path)\n".utf8))
            exit(1)
        }

        var rendered = 0
        for url in pngs {
            // "icon_512x512@2x.png" -> 1024 points
            let name = url.deletingPathExtension().lastPathComponent
            guard let sizePart = name.split(separator: "_").last,
                  let points = Double(sizePart.split(separator: "x").first ?? "") else { continue }
            let scale = name.contains("@2x") ? 2.0 : 1.0
            let pixels = points * scale

            // A macOS icon is a rounded square inset in its canvas, drawn at 824/1024.
            let canvas = CGFloat(pixels)
            let content = ZStack {
                WhaleTile(size: canvas * 0.82)
            }
            .frame(width: canvas, height: canvas)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: url)
            rendered += 1
        }
        print("rendered \(rendered) icon size(s)")
    }
}
