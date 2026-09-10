import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

/// Per-day record of what this app observed. The only cost figure DeepSeek exposes for an
/// API key is the current balance, so per-day spend is *derived* by watching that balance
/// fall. Every derived number is labelled as an estimate in the UI.
struct DayRecord: Codable, Identifiable {
    var day: String                 // "2026-09-10", schedule timezone
    var startBalance: Double
    var endBalance: Double
    var spend: Double
    var topUp: Double
    var readCount: Int
    var firstSeen: Date
    var lastSeen: Date

    var id: String { day }
    var isEstimated: Bool { topUp > 0 }
    var netChange: Double { startBalance - endBalance }
}

struct Ledger: Codable {
    var version: Int = 1
    var days: [DayRecord] = []

    static let keepDays = 120

    mutating func record(_ day: String, balance: Double, at date: Date) {
        if var existing = days.first(where: { $0.day == day }) {
            if balance > existing.endBalance {
                existing.topUp += balance - existing.endBalance
            } else {
                existing.spend += existing.endBalance - balance
            }
            existing.endBalance = balance
            existing.lastSeen = date
            existing.readCount += 1
            if let i = days.firstIndex(where: { $0.day == day }) { days[i] = existing }
        } else {
            days.append(DayRecord(day: day, startBalance: balance, endBalance: balance,
                                  spend: 0, topUp: 0, readCount: 1,
                                  firstSeen: date, lastSeen: date))
        }
        days.sort { $0.day < $1.day }
        if days.count > Self.keepDays { days.removeFirst(days.count - Self.keepDays) }
    }
}

enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DeepSeekBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }

    static func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    static func saveLedger(_ ledger: Ledger) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }
}

// MARK: - Settings

final class Settings: ObservableObject {
    static let shared = Settings()

    enum MenuBarStyle: String, CaseIterable, Codable {
        case iconStatus, iconStatusBalance, iconBalance, iconOnly

        var label: String {
            switch self {
            case .iconStatus: return "Icon + status"
            case .iconStatusBalance: return "Icon + status + balance"
            case .iconBalance: return "Icon + balance"
            case .iconOnly: return "Icon only"
            }
        }
    }

    @Published var menuBarStyle: MenuBarStyle { didSet { save() } }
    @Published var showSavings: Bool { didSet { save() } }
    @Published var use24HourClock: Bool { didSet { save() } }
    @Published var notifyOnTransition: Bool { didSet { save() } }
    @Published var refreshInterval: Double { didSet { save() } }

    private let defaults = UserDefaults.standard
    private var loading = true

    private init() {
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .iconStatusBalance
        showSavings = defaults.object(forKey: "showSavings") as? Bool ?? true
        use24HourClock = defaults.object(forKey: "use24HourClock") as? Bool ?? true
        notifyOnTransition = defaults.object(forKey: "notifyOnTransition") as? Bool ?? true
        let stored = defaults.double(forKey: "refreshInterval")
        refreshInterval = stored > 0 ? stored : 90
        loading = false
    }

    private func save() {
        guard !loading else { return }
        defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
        defaults.set(showSavings, forKey: "showSavings")
        defaults.set(use24HourClock, forKey: "use24HourClock")
        defaults.set(notifyOnTransition, forKey: "notifyOnTransition")
        defaults.set(refreshInterval, forKey: "refreshInterval")
        NotificationCenter.default.post(name: .dsbSettingsChanged, object: nil)
    }

    var refreshIntervalClamped: TimeInterval { min(max(refreshInterval, 30), 900) }
}

extension Notification.Name {
    static let dsbSettingsChanged = Notification.Name("dsb.settingsChanged")
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {    static let shared = Store()

    // Live schedule — recomputed on a fast timer so the countdown ticks.
    @Published private(set) var mode: PricingMode = .offPeak
    @Published private(set) var now: Date = Date()
    @Published private(set) var nextTransition: Date = Date()
    @Published private(set) var modeFlipFlash: Bool = false

    // Account
    @Published private(set) var balance: AccountBalance?
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var keyIsValid: Bool?

    @Published private(set) var ledger: Ledger = Storage.loadLedger()

    // Console-sourced figures: real billed cost and token counts, not estimates.
    @Published private(set) var platformUsage: PlatformUsage?
    @Published private(set) var platformSyncing = false
    @Published private(set) var platformError: String?
    @Published private(set) var perKeyUsage: [NamedTokenRow] = []
    @Published private(set) var topUps: [TopUp] = []

    let platform = PlatformAPI()

    var isConnectedToConsole: Bool { Credentials.consoleToken != nil }

    private let api = DeepSeekAPI()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var platformTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        refreshSchedule()
        // Cheap UI tick: the countdown and the "now" marker must feel live.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let t = tickTimer { RunLoop.main.add(t, forMode: .common) }

        NotificationCenter.default.addObserver(forName: .dsbSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefreshTimer() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSchedule()
                await self?.sync()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        scheduleRefreshTimer()
        schedulePlatformTimer()
    }

    // MARK: Schedule

    private func tick() {
        now = Date()
        let newMode = Schedule.mode(at: now)
        if newMode != mode {
            mode = newMode
            refreshSchedule()
            flashModeChange()
            if Settings.shared.notifyOnTransition { notifyModeChange() }
        }
        // Keep the transition target fresh across day boundaries.
        if nextTransition.timeIntervalSince(now) <= 0 { refreshSchedule() }
    }

    private func refreshSchedule() {
        now = Date()
        mode = Schedule.mode(at: now)
        nextTransition = Schedule.nextTransition(after: now)
    }

    private func flashModeChange() {
        modeFlipFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            self.modeFlipFlash = false
        }
    }

    private func notifyModeChange() {
        let title = "DeepSeek \(mode.title) rates"
        let body = mode == .peak
            ? "Peak pricing is live — 2× off-peak rates until \(Fmt.clock(nextTransition, timeZone: Schedule.timeZone)) UTC."
            : "Off-peak pricing is live — half price until \(Fmt.clock(nextTransition, timeZone: Schedule.timeZone)) UTC."

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    var timeUntilTransition: TimeInterval { max(0, nextTransition.timeIntervalSince(now)) }

    // MARK: Polling

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = Credentials.apiKey.isEmpty ? 300 : Settings.shared.refreshIntervalClamped
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        if let t = refreshTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// The console endpoints are heavier and rate-sensitive, so they refresh on their
    /// own slow cadence rather than on every balance poll.
    private func schedulePlatformTimer() {
        platformTimer?.invalidate()
        platformTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncPlatform() }
        }
        if let t = platformTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func sync() async {
        let key = Credentials.apiKey
        guard !key.isEmpty else {
            keyIsValid = nil
            lastError = APIError.missingKey.errorDescription
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let balance = try await api.balance(apiKey: key)
            apply(balance: balance)
            keyIsValid = true
            lastError = nil
            lastSync = Date()
            if isConnectedToConsole {
                Task { await self.syncPlatform() }
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case APIError.unauthorized = error { keyIsValid = false }
        }
    }

    private func apply(balance: AccountBalance) {
        self.balance = balance
        let day = Self.dayKey(for: Date())
        ledger.record(day, balance: balance.total, at: Date())
        Storage.saveLedger(ledger)
        objectWillChange.send()
    }

    // MARK: Console sync

    /// Pulls the console's own billed figures. Best-effort: the menu bar works from the
    /// public balance API alone, and this layer adds authoritative cost and tokens.
    func syncPlatform() async {
        guard isConnectedToConsole else {
            platformError = nil
            return
        }
        guard !platformSyncing else { return }
        platformSyncing = true
        defer { platformSyncing = false }

        do {
            let range = try PlatformAPI.window(days: 30, calendar: .current)
            let usage = try await platform.usageHistory(days: 30)
            platformUsage = usage
            platformError = nil
            lastSync = Date()

            // One extra pair of calls for the per-key breakdown, using the same window.
            if let cost = try? await platform.rawCost(range: range),
               let amount = try? await platform.rawAmount(range: range) {
                perKeyUsage = PlatformAPI.perKey(cost: cost, amount: amount, calendar: .current)
            }

            if let summary = try? await platform.summary() {
                self.balance = summary.balance
                // Lifetime cost rides along with the summary call.
                var updated = usage
                updated.lifetimeCost = summary.lifetimeCost
                updated.lifetimeCurrency = summary.currency
                platformUsage = updated
            }
        } catch {
            platformError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshTopUps() async {
        guard isConnectedToConsole else { return }
        if let invoices = try? await platform.invoices() {
            topUps = invoices
        }
    }

    static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Schedule.timeZone
        return f.string(from: date)
    }

    // MARK: Derived figures

    var today: DayRecord? { ledger.days.last { $0.day == Self.dayKey(for: Date()) } }

    /// Spend today, preferring the console's billed figure and falling back to the
    /// balance-drop estimate when the console is not connected.
    var spentToday: Double {
        if let day = platformUsage?.day(for: Date(), calendar: .current) { return day.cost }
        return today?.spend ?? 0
    }

    var todayUsage: UsageDay? {
        platformUsage?.day(for: Date(), calendar: .current)
    }

    /// Whether the displayed spend is DeepSeek's own number or this app's estimate.
    var spendIsBilled: Bool { platformUsage?.day(for: Date(), calendar: .current) != nil }

    var lifetimeCost: Double? { platformUsage?.lifetimeCost }

    var todayTokens: TokenCounts { todayUsage?.tokens ?? TokenCounts() }
    var todayRequests: Int { todayUsage?.requests ?? 0 }

    /// Observed spend across the whole retained window (estimate path).
    var spentTracked: Double { ledger.days.reduce(0) { $0 + $1.spend } }

    /// Daily spend series for the mini chart, oldest first. Real data when available.
    var spendSeries: [(day: String, spend: Double)] {
        if let usage = platformUsage, !usage.days.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM"
            return usage.days.suffix(14).map { (formatter.string(from: $0.date), $0.cost) }
        }
        return ledger.days.suffix(14).map { ($0.day, $0.spend) }
    }

    var hasTrackedData: Bool {
        if platformUsage?.days.isEmpty == false { return true }
        return ledger.days.contains { $0.readCount > 1 }
    }

    /// What today's tokens would have cost at peak rates — the money the off-peak
    /// window is actually saving, computed from real token counts.
    var todaySavings: Double? {
        guard let usage = todayUsage, !usage.tokens.isEmpty else { return nil }
        let peak = usage.peakEquivalentCost()
        let saved = peak - usage.cost
        return saved > 0.000001 ? saved : nil
    }

    /// Share of input tokens served from cache — the single biggest cost lever.
    var todayCacheHitRate: Double? {
        guard let usage = todayUsage, usage.tokens.totalInput > 0 else { return nil }
        return usage.hitRate
    }

    var projectedTokensFromBalance: UInt64 {
        guard let b = balance, b.total > 0 else { return 0 }
        let missRate = Rate.flash.rates(for: mode).miss
        guard missRate > 0 else { return 0 }
        return UInt64((b.total / missRate) * 1_000_000)
    }

    /// Sub-line under the balance: what backs it.
    var balanceSubtitle: String {
        guard let b = balance else { return "Not synced yet" }
        if b.granted > 0 {
            return "\(Fmt.money(b.toppedUp, decimals: 2)) topped up · \(Fmt.money(b.granted, decimals: 2)) granted"
        }
        return "Topped-up balance"
    }

    var menuBarStatusText: String {
        switch mode {
        case .peak: return "peak"
        case .offPeak: return "cheap"
        }
    }

    var keyStatusText: String {        if Credentials.apiKey.isEmpty { return "Not connected" }
        if keyIsValid == false { return "Key rejected" }
        if let err = lastError, balance == nil { return "Error — \(err)" }
        guard let last = lastSync else { return "Connecting…" }
        let ago = Int(Date().timeIntervalSince(last))
        if ago < 10 { return "Synced just now" }
        if ago < 90 { return "Synced \(ago)s ago" }
        return "Synced \(ago / 60)m ago"
    }

    // MARK: Test connection

    func testKey(_ key: String) async -> Result<[String], Error> {
        do {
            let models = try await api.modelIDs(apiKey: key)
            return .success(models)
        } catch {
            return .failure(error)
        }
    }
}
