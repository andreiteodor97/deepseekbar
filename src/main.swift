import AppKit
import Cocoa

func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

func isPeak(_ hour: Int, _ weekday: Int) -> Bool {
    let workday = weekday >= 2 && weekday <= 6
    guard workday else { return false }
    return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10)
}

let baseHit = 0.003
let baseMiss = 0.15
let baseOut = 0.6

func fmt(_ v: Double) -> String {
    return v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v)
}

func nowUTC() -> (hour: Int, minute: Int, weekday: Int) {
    let c = utcCalendar().dateComponents([.hour, .minute, .weekday], from: Date())
    return (c.hour ?? 0, c.minute ?? 0, c.weekday ?? 1)
}

func nextTransition(_ cur: (hour: Int, minute: Int, weekday: Int)) -> Date {
    let now = Date()
    let utc = utcCalendar()
    for m in 1...20000 {
        let t = now.addingTimeInterval(TimeInterval(m * 60))
        let c = utc.dateComponents([.hour, .weekday], from: t)
        if isPeak(c.hour ?? 0, c.weekday ?? 1) != isPeak(cur.hour, cur.weekday) {
            return t
        }
    }
    return now.addingTimeInterval(3600)
}

func relative(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    let h = m / 60
    let mm = m % 60
    if h > 0 { return "\(h)h \(mm)m" }
    return "\(mm)m"
}

func utcHM(_ date: Date) -> String {
    let c = utcCalendar().dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

func localHM(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = TimeZone.current
    return f.string(from: date)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createItem()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            self.update()
        }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            self.recreateItem()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(recreateItem), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recreateItem), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func createItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "DeepSeekBarItem"
        update()
    }

    @objc func recreateItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        createItem()
        log("recreated status item")
    }

    func log(_ msg: String) {
        FileManager.default.createFile(atPath: "/tmp/dsbar.log", contents: nil)
        if let h = FileHandle(forWritingAtPath: "/tmp/dsbar.log") {
            h.seekToEndOfFile()
            h.write("\(Date()) \(msg)\n".data(using: .utf8)!)
            h.closeFile()
        }
    }

    func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func update() {
        let now = Date()
        let cur = nowUTC()
        let peak = isPeak(cur.hour, cur.weekday)
        let mult = peak ? 2.0 : 1.0

        if let btn = statusItem.button {
            let title = peak ? "DS \u{25CF} peak" : "DS \u{25CF} cheap"
            btn.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: peak ? NSColor.systemRed : NSColor.systemGreen])
        }
        statusItem.isVisible = true
        log("peak=\(peak) itemVisible=\(statusItem.isVisible) titleSet=true")

        let menu = NSMenu()
        menu.addItem(info("DeepSeek Flash — \(peak ? "PEAK" : "OFF-PEAK")"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(info("input cache hit:  \(fmt(baseHit * mult))/M"))
        menu.addItem(info("input cache miss: \(fmt(baseMiss * mult))/M"))
        menu.addItem(info("output:           \(fmt(baseOut * mult))/M"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(info("Peak hours (Mon–Fri, UTC): 01:00–04:00 & 06:00–10:00"))
        menu.addItem(info("Now: \(utcHM(now)) UTC · \(localHM(now)) local"))
        let next = nextTransition(cur)
        menu.addItem(info("Next switch: \(utcHM(next)) UTC (in \(relative(next.timeIntervalSince(now))))"))
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit DeepSeekBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
