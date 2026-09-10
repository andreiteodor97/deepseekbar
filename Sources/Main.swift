import AppKit
import SwiftUI
import Combine

/// Append-only diagnostics at /tmp/dsbar.log. A menu-bar app has nowhere to print,
/// and a silent failure here means an invisible status item.
enum DebugLog {
    static let url = URL(fileURLWithPath: "/tmp/dsbar.log")

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Panel

@MainActor
final class PanelController: NSObject {
    private var panel: NSPanel?
    private var monitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(relativeTo button: NSStatusBarButton, content: some View) {
        let panel = existingPanel() ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        if let container = panel.contentView {
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // `fittingSize` is wrong until the view has been through a layout pass, which is
        // what left the panel too short and clipped its own footer. Give it a real pass
        // at the final width before asking how tall it wants to be.
        let width: CGFloat = 372
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosting.layoutSubtreeIfNeeded()
        let needed = hosting.fittingSize.height

        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Short tabs would otherwise produce a stubby window.
        let height = min(max(needed, 380), max(320, visible.height - 24))
        let size = NSSize(width: width, height: height)
        panel.setContentSize(size)

        // Anchor under the status item, clamped to the screen.
        let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        installMonitor()

        DebugLog.write("panel shown needed=\(Int(needed)) used=\(Int(height))")
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
        panel = nil
    }

    private func existingPanel() -> NSPanel? { panel }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSApp.effectiveAppearance

        // Rounded, shadowed container so the panel reads like a native popover.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        panel.contentView = container

        return panel
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let panel = PanelController()
    private let consoleWindow = ConsoleWindowController()
    private let store = Store.shared
    private let settings = Settings.shared
    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Timer?
    private var lastRebuild = Date.distantPast
    private var recentlyRebuilt: Bool { Date().timeIntervalSince(lastRebuild) < 5 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same status-item slot and ledger file.
        let bundleID = Bundle.main.bundleIdentifier ?? "local.deepseekbar"
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if copies.count > 1 {
            DebugLog.write("another instance is already running (\(copies.count)); exiting")
            NSApp.terminate(nil)
            return
        }

        Credentials.migrateFromKnownLocations()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "DeepSeekBarItem"

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderStatusItem() }
            .store(in: &cancellables)

        store.$balance
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderStatusItem() }
            .store(in: &cancellables)

        settings.$menuBarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderStatusItem() }
            .store(in: &cancellables)

        renderStatusItem()
        store.requestNotificationPermission()
        Task { await store.sync() }

        // Safety net for evictions with no notification of their own. Recreating is
        // cheap and does not flicker, so this is a fine trade for never disappearing.
        let timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [self] _ in
            Task { @MainActor in self.rebuildStatusItem(reason: "heartbeat") }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(rebuildStatusItemOnWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screenConfigurationChanged() {
        if panel.isVisible { panel.close() }
        rebuildStatusItem(reason: "screen change")
    }

    /// The menu bar can drop a status item — after a display change, a `SystemUIServer`
    /// restart, a login, or a wake from sleep — while the process keeps running happily.
    /// From the user's side the app has simply vanished, which is the worst possible
    /// failure for a menu bar app.
    ///
    /// There is no API that reports the eviction: `isVisible` stays `true`, and status
    /// items do not appear in the window-server window list at all. So this rebuilds the
    /// item on every event known to cause an eviction, plus a slow heartbeat as a net.
    /// Rebuilding is cheap and invisible — it re-renders the same image into the same slot.
    private func rebuildStatusItem(reason: String) {
        guard Date().timeIntervalSince(lastRebuild) > 3 else { return }
        lastRebuild = Date()
        DebugLog.write("rebuilding status item (\(reason))")

        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "DeepSeekBarItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        renderStatusItem()
    }

    @objc private func rebuildStatusItemOnWake() {
        rebuildStatusItem(reason: "wake")
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            panel.close()
            return
        }
        panel.show(relativeTo: button, content: panelContent)
    }

    private var panelContent: some View {
        PanelView(
            store: store,
            settings: settings,
            onOpenPlatform: {
                NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
                self.panel.close()
            },
            onConnectConsole: {
                self.panel.close()
                self.consoleWindow.show { _ in
                    Task {
                        await self.store.syncPlatform()
                        await self.store.refreshTopUps()
                    }
                }
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else {
            DebugLog.write("renderStatusItem: no button")
            return
        }
        let scale = button.window?.backingScaleFactor ?? 2

        var balanceText: String?
        switch settings.menuBarStyle {
        case .iconBalance, .iconStatusBalance:
            if let b = store.balance {
                balanceText = Fmt.moneyCompact(b.total)
            }
        case .iconOnly, .iconStatus:
            balanceText = nil
        }

        let label = MenuBarLabel(mode: store.mode, balanceText: balanceText, style: settings.menuBarStyle)
        if let image = StatusItemRenderer.image(for: label, scale: scale) {
            button.image = image
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = tooltip()
            DebugLog.write("render: style=\(settings.menuBarStyle) mode=\(store.mode) balance=\(balanceText ?? "nil") img=\(image.size) visible=\(statusItem.isVisible) buttonFrame=\(button.frame)")
        } else {
            DebugLog.write("render: NIL IMAGE")
        }
    }

    private func tooltip() -> String {
        var parts: [String] = []
        parts.append(store.mode == .peak ? "Peak rates (×2)" : "Off-peak rates (×1)")
        parts.append("Switches in \(Fmt.countdown(store.timeUntilTransition))")
        if let b = store.balance { parts.append("Balance \(Fmt.money(b.total, decimals: 2))") }
        if store.spentToday > 0 { parts.append("Spent today \(Fmt.money(store.spentToday, decimals: 4))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Entry point

@main
struct DeepSeekBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
