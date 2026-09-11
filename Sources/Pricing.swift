import Foundation

// MARK: - Rate card
//
// Authoritative source: https://api-docs.deepseek.com/quick_start/pricing
// Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday.
// Off-peak rates are exactly half of peak rates.

/// A per-model rate card, in USD per 1M tokens.
struct RateCard {
    let modelID: String
    let displayName: String
    /// USD per 1M input tokens, cache hit.
    let cacheHit: Double
    /// USD per 1M input tokens, cache miss.
    let cacheMiss: Double
    /// USD per 1M output tokens.
    let output: Double

    /// Peak rates are 2x off-peak.
    var peak: RateCard { RateCard(modelID: modelID, displayName: displayName, cacheHit: cacheHit * 2, cacheMiss: cacheMiss * 2, output: output * 2) }

    func rates(for mode: PricingMode) -> (hit: Double, miss: Double, out: Double) {
        let m = mode.multiplier
        return (cacheHit * m, cacheMiss * m, output * m)
    }
}

struct TokenCounts: Equatable {
    var cacheHit: UInt64 = 0
    var cacheMiss: UInt64 = 0
    var output: UInt64 = 0

    var totalInput: UInt64 { cacheHit &+ cacheMiss }
    var total: UInt64 { totalInput &+ output }
    var isEmpty: Bool { cacheHit == 0 && cacheMiss == 0 && output == 0 }

    static func + (l: TokenCounts, r: TokenCounts) -> TokenCounts {
        TokenCounts(cacheHit: l.cacheHit &+ r.cacheHit, cacheMiss: l.cacheMiss &+ r.cacheMiss, output: l.output &+ r.output)
    }
}

enum Rate {
    /// Both live models bill as Flash. `deepseek-v4-pro` is being retired and is
    /// routed to V4.1 Flash at Flash prices, so it shares the same card.
    static let flash = RateCard(modelID: "deepseek-flash", displayName: "DeepSeek V4.1 Flash", cacheHit: 0.003, cacheMiss: 0.15, output: 0.60)
    static let pro = RateCard(modelID: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", cacheHit: 0.022, cacheMiss: 0.66, output: 1.98)

    static let all: [RateCard] = [flash, pro]

    static func card(for modelID: String?) -> RateCard {
        guard let id = modelID?.lowercased() else { return flash }
        if id.contains("pro") { return pro }
        return flash
    }

    /// Cost in USD of `tokens` at `card`, in `mode`.
    static func cost(_ tokens: TokenCounts, card: RateCard, mode: PricingMode) -> Double {
        let r = card.rates(for: mode)
        return (Double(tokens.cacheHit) / 1_000_000) * r.hit
            + (Double(tokens.cacheMiss) / 1_000_000) * r.miss
            + (Double(tokens.output) / 1_000_000) * r.out
    }
}

// MARK: - Peak / off-peak schedule

enum PricingMode: String, Codable, CaseIterable {
    case peak
    case offPeak

    var multiplier: Double { self == .peak ? 2 : 1 }
    var shortLabel: String { self == .peak ? "PEAK" : "OFF-PEAK" }
    var title: String { self == .peak ? "Peak" : "Off-peak" }
}

/// A half-open interval of peak time, expressed in the schedule's own timezone.
struct PeakWindow {
    let startHour: Int
    let endHour: Int
    func contains(hour: Int) -> Bool { hour >= startHour && hour < endHour }
    var label: String { String(format: "%02d:00–%02d:00", startHour, endHour) }
}

enum Schedule {
    /// DeepSeek bills "working days" against UTC.
    static let timeZone = TimeZone(identifier: "UTC")!

    static let peakWindows: [PeakWindow] = [
        PeakWindow(startHour: 1, endHour: 4),
        PeakWindow(startHour: 6, endHour: 10),
    ]

    /// Weekdays are Monday–Friday. In Foundation, `.weekday` is 1=Sunday…7=Saturday.
    static func isWorkday(weekday: Int) -> Bool { weekday >= 2 && weekday <= 6 }

    static func isPeak(hour: Int, weekday: Int) -> Bool {
        guard isWorkday(weekday: weekday) else { return false }
        return peakWindows.contains { $0.contains(hour: hour) }
    }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    static func mode(at date: Date) -> PricingMode {
        let c = calendar.dateComponents([.hour, .weekday], from: date)
        return isPeak(hour: c.hour ?? 0, weekday: c.weekday ?? 1) ? .peak : .offPeak
    }

    /// The instant the schedule next flips between peak and off-peak.
    ///
    /// Walks forward minute by minute — at most a weekend's worth of minutes — which is
    /// cheap, exact, and immune to the off-by-one errors of arithmetic window math.
    static func nextTransition(after date: Date) -> Date {
        let c = calendar
        let current = mode(at: date)
        // 4 days covers the longest possible off-peak run (Fri 10:00 UTC → Mon 01:00 UTC).
        let limit = 4 * 24 * 60 + 1
        var minute = 1
        while minute <= limit {
            guard let t = c.date(byAdding: .minute, value: minute, to: date) else { break }
            if mode(at: t) != current { return t }
            minute += 1
        }
        return date.addingTimeInterval(3600)
    }

    /// Start of the next peak window, or nil if one is already running. This is the
    /// actionable number: it is when waiting a while starts saving real money.
    static func nextPeakStart(after date: Date) -> Date? {
        mode(at: date) == .peak ? nil : nextTransition(after: date)
    }

    /// Whether one of the two windows is running right now, and when the next one opens.
    static func peakState(at date: Date) -> (isPeakNow: Bool, nextPeak: Date?) {
        (mode(at: date) == .peak, nextPeakStart(after: date))
    }

    /// Seconds until the mode flips.
    static func timeUntilTransition(from date: Date) -> TimeInterval {
        nextTransition(after: date).timeIntervalSince(date)
    }

    /// The 24 hours of `date`'s day in the schedule timezone, with peak flags.
    /// Used to draw the day timeline.
    static func hourlyModes(for date: Date) -> [(hour: Int, weekday: Int, isPeak: Bool)] {
        let c = calendar
        let start = c.startOfDay(for: date)
        return (0..<24).map { h in
            let t = c.date(byAdding: .hour, value: h, to: start) ?? start
            let comps = c.dateComponents([.hour, .weekday], from: t)
            let hour = comps.hour ?? 0
            let weekday = comps.weekday ?? 1
            return (hour, weekday, isPeak(hour: hour, weekday: weekday))
        }
    }

    /// Peak windows that fall inside a given local day, for display in the user's timezone.
    /// Returns wall-clock ranges in `timeZone` (defaults to the user's current zone).
    static func localPeakRanges(for date: Date, in timeZone: TimeZone = .current) -> [(start: Date, end: Date)] {
        let utc = calendar
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let localStart = local.startOfDay(for: date)
        guard let localEnd = local.date(byAdding: .day, value: 1, to: localStart) else { return [] }

        var out: [(Date, Date)] = []
        // Walk the UTC day before/after too, since the local day can straddle two UTC days.
        for dayOffset in -1...1 {
            guard let utcDay = utc.date(byAdding: .day, value: dayOffset, to: utc.startOfDay(for: date)) else { continue }
            let weekday = utc.component(.weekday, from: utcDay)
            guard isWorkday(weekday: weekday) else { continue }
            for w in peakWindows {
                guard let s = utc.date(byAdding: .hour, value: w.startHour, to: utcDay),
                      let e = utc.date(byAdding: .hour, value: w.endHour, to: utcDay) else { continue }
                if e > localStart && s < localEnd { out.append((s, e)) }
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

// MARK: - Formatting

enum Fmt {
    static func money(_ v: Double, decimals: Int? = nil) -> String {
        if let d = decimals { return String(format: "$%.\(d)f", v) }
        if v == 0 { return "$0.00" }
        if abs(v) < 0.01 { return String(format: "$%.4f", v) }
        return String(format: "$%.2f", v)
    }

    /// Compact money for the menu bar: $5.28, $0.042, $12.30
    static func moneyCompact(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.01 { return String(format: "$%.3f", v) }
        return String(format: "$%.0f", v)
    }

    static func tokens(_ n: UInt64) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.2fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }

    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "in 8h 50m" / "in 42m" / "in 30s"
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = timeZone
        return f.string(from: date)
    }
}
