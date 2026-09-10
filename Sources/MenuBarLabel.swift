import AppKit
import SwiftUI

// MARK: - Menu bar item

/// Painted with ImageRenderer instead of a text button, which buys precise control of
/// the glyph, the live colour, and the balance readout in one go.
struct MenuBarLabel: View {
    static let barHeight: CGFloat = 22
    /// Menu bar items are given 22pt, and macOS keeps a few points of that as breathing
    /// room. Anything taller is silently clipped to nothing.
    static let glyphHeight: CGFloat = 13

    let mode: PricingMode
    let balanceText: String?
    let style: Settings.MenuBarStyle

    var body: some View {
        HStack(spacing: 4) {
            WhaleMark(size: Self.glyphHeight, color: .black)
            if let text = text {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 1)
        .frame(height: Self.barHeight)
    }

    /// "cheap $5.24" — whichever parts this style asks for.
    private var text: String? {
        var parts: [String] = []
        switch style {
        case .iconOnly:
            return nil
        case .iconBalance, .iconStatusBalance:
            if let balanceText { parts.append(balanceText) }
        case .iconStatus:
            break
        }
        if style != .iconBalance {
            parts.append(mode == .peak ? "peak" : "cheap")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Renders a SwiftUI view to a 1x/2x-aware template image for the status item.
@MainActor
enum StatusItemRenderer {
    static func image(for view: some View, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        let image = NSImage(cgImage: cg, size: size)
        image.isTemplate = true
        return image
    }
}
