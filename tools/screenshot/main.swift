import AppKit
import SwiftUI

/// Renders the panel to a PNG without needing a live account or a quiet desktop.
///
/// Documentation screenshots taken with `screencapture` depend on whatever happens to be
/// behind the window, which makes them impossible to reproduce. This draws the real
/// `PanelView` offscreen with fixed sample data instead:
///
///   ./tools/screenshot.sh
///
/// The numbers below are illustrative, not live.
@MainActor
enum Screenshot {
    static func run() {
        let store = Store.shared
        injectSampleData(into: store, settings: Settings.shared)

        let directory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "docs"

        // Fixed width, natural height: the panel sizes itself to its content, so the
        // image has no dead space at the bottom.
        let width: CGFloat = 372

        for (name, tab) in [("panel", PanelView.Tab.rate),
                            ("panel-usage", .usage),
                            ("panel-settings", .settings)] {
            let view = PanelView(
                store: store,
                settings: Settings.shared,
                initialTab: tab,
                onOpenPlatform: {},
                onConnectConsole: {},
                onQuit: {}
            )
            .frame(width: width)
            // ImageRenderer cannot draw NSVisualEffectView; it renders the system's
            // "no content" placeholder instead. The panel swaps to a flat background.
            .environment(\.dsbOpaqueBackground, true)
            // Documentation is read on dark backgrounds, which is also how most people
            // run the app.
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                exit(1)
            }

            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
            print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
        exit(0)
    }

    /// Sample figures so the panel shows every element. Deliberately close to a real
    /// account's shape: a small topped-up balance, a busy day, a high cache-hit rate.
    private static func injectSampleData(into store: Store, settings: Settings) {
        let card = Rate.flash

        // A believable day: mostly cached input, which is what real agent traffic looks
        // like and what makes the savings line meaningful.
        let tokens = TokenCounts(cacheHit: 178_387_200, cacheMiss: 520_617, output: 153_472)
        let today = UsageDay(
            date: Date(),
            cost: Rate.cost(tokens, card: card, mode: .offPeak),
            tokens: tokens,
            requests: 207
        )

        var days: [UsageDay] = []
        let calendar = Calendar.current
        // Oldest first; the last entry is today and reuses today's exact figures so the
        // "Today" card and the trailing chart agree.
        let history: [Double] = [0.21, 0.38, 0.96, 0.41, 0.73, 0.29, 0.55, 1.02, 0.64,
                                 0.31, 0.87, 1.24, 0.18]
        for (offset, cost) in history.enumerated().reversed() {
            guard let date = calendar.date(byAdding: .day, value: -(offset + 1), to: today.date) else { continue }
            let share = cost / 6.8
            days.append(UsageDay(
                date: date,
                cost: cost,
                tokens: TokenCounts(
                    cacheHit: UInt64(Double(tokens.cacheHit) * share),
                    cacheMiss: UInt64(Double(tokens.cacheMiss) * share),
                    output: UInt64(Double(tokens.output) * share)
                ),
                requests: Int(Double(today.requests) * share) + 3
            ))
        }
        days.append(today)

        store.applySampleData(
            balance: AccountBalance(currency: "USD", total: 5.04, granted: 0, toppedUp: 5.04),
            usage: PlatformUsage(lifetimeCost: 24.94, lifetimeCurrency: "USD", days: days, fetchedAt: Date()),
            perKey: [
                NamedTokenRow(id: "1", name: "harness", cost: 3.91,
                              tokens: tokens, requests: 1_204),
                NamedTokenRow(id: "2", name: "essay-manager", cost: 1.42,
                              tokens: TokenCounts(cacheHit: 41_000_000, cacheMiss: 210_000, output: 61_000),
                              requests: 502),
            ],
            connected: true
        )
    }
}

// Top-level entry point: kept as `main.swift` so this can be compiled alongside the
// app's sources, whose own `@main` is excluded by tools/screenshot.sh.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { Screenshot.run() }
