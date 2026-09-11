// Rate and schedule test suite for DeepSeekBar.
//
// These are the parts most likely to be subtly wrong: a mis-set weekday means the menu
// bar confidently reports the wrong price for hours at a time. Run with ./test.sh.
//
// Lives in its own directory as `main.swift` so Swift permits top-level statements.

import Foundation

var failures = 0
func check(_ label: String, _ actual: String, _ expected: String) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label): got \(actual), want \(expected)")
}

let utc = Schedule.calendar
func date(_ iso: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = TimeZone(identifier: "UTC")!
    return f.date(from: iso)!
}

// Known dates: 2026-09-07 is a Monday.
check("Mon 00:59 UTC", Schedule.mode(at: date("2026-09-07 00:59")).rawValue, "offPeak")
check("Mon 01:00 UTC", Schedule.mode(at: date("2026-09-07 01:00")).rawValue, "peak")
check("Mon 03:59 UTC", Schedule.mode(at: date("2026-09-07 03:59")).rawValue, "peak")
check("Mon 04:00 UTC", Schedule.mode(at: date("2026-09-07 04:00")).rawValue, "offPeak")
check("Mon 06:00 UTC", Schedule.mode(at: date("2026-09-07 06:00")).rawValue, "peak")
check("Mon 10:00 UTC", Schedule.mode(at: date("2026-09-07 10:00")).rawValue, "offPeak")
check("Fri 09:00 UTC", Schedule.mode(at: date("2026-09-11 09:00")).rawValue, "peak")
check("Fri 12:00 UTC", Schedule.mode(at: date("2026-09-11 12:00")).rawValue, "offPeak")
// The critical weekend boundary: Saturday must never be peak.
check("Sat 02:00 UTC", Schedule.mode(at: date("2026-09-12 02:00")).rawValue, "offPeak")
check("Sat 07:00 UTC", Schedule.mode(at: date("2026-09-12 07:00")).rawValue, "offPeak")
check("Sun 02:00 UTC", Schedule.mode(at: date("2026-09-13 02:00")).rawValue, "offPeak")
check("Mon 02:00 UTC", Schedule.mode(at: date("2026-09-14 02:00")).rawValue, "peak")

// Transitions
check("next transition from Fri 09:30", Fmt.clock(Schedule.nextTransition(after: date("2026-09-11 09:30")), timeZone: utc.timeZone), "10:00")
check("next transition from Fri 12:00", Fmt.clock(Schedule.nextTransition(after: date("2026-09-11 12:00")), timeZone: utc.timeZone), "01:00")
check("next transition from Mon 02:00", Fmt.clock(Schedule.nextTransition(after: date("2026-09-07 02:00")), timeZone: utc.timeZone), "04:00")
check("next transition from Mon 05:00", Fmt.clock(Schedule.nextTransition(after: date("2026-09-07 05:00")), timeZone: utc.timeZone), "06:00")
// Friday 12:00 -> Monday 01:00 is 61 hours, the longest off-peak run.
let gap = Schedule.nextTransition(after: date("2026-09-11 12:00")).timeIntervalSince(date("2026-09-11 12:00")) / 3600
check("Fri 12:00 -> next peak (hours)", String(format: "%.0f", gap), "61")

// Countdown formatting
check("countdown 8h50m", Fmt.countdown(8 * 3600 + 50 * 60), "8h 50m")
check("countdown 42m", Fmt.countdown(42 * 60), "42m")
check("countdown 30s", Fmt.countdown(30), "30s")

// Money formatting
check("money tiny", Fmt.money(0.003), "$0.0030")
check("money small", Fmt.money(0.15), "$0.15")
check("money 2dp", Fmt.money(24.7565718, decimals: 2), "$24.76")
check("compact >=1", Fmt.moneyCompact(5.2434), "$5.24")
check("compact <1", Fmt.moneyCompact(0.0421), "$0.042")
check("tokens M", Fmt.tokens(1_893_101_164), "1.89B")
check("tokens K", Fmt.tokens(12_345), "12.3K")

// Cost math at both modes: 1M hit + 1M miss + 1M out
let tokens = TokenCounts(cacheHit: 1_000_000, cacheMiss: 1_000_000, output: 1_000_000)
check("cost off-peak", String(format: "%.3f", Rate.cost(tokens, card: Rate.flash, mode: .offPeak)), "0.753")
check("cost peak", String(format: "%.3f", Rate.cost(tokens, card: Rate.flash, mode: .peak)), "1.506")
check("peak is 2x", String(format: "%.0f", Rate.cost(tokens, card: Rate.flash, mode: .peak) / Rate.cost(tokens, card: Rate.flash, mode: .offPeak)), "2")

// Timezone projection: local time is UTC + 4, so the 01:00-04:00 UTC window lands at
// 05:00-08:00 local, and 06:00-10:00 UTC lands at 10:00-14:00 local.
let tz4 = TimeZone(secondsFromGMT: 4 * 3600)!
let ranges = Schedule.localPeakRanges(for: date("2026-09-07 12:00"), in: tz4)
let rendered = ranges.map { "\(Fmt.clock($0.start, timeZone: tz4))-\(Fmt.clock($0.end, timeZone: tz4))" }.joined(separator: ",")
check("UTC+4 local windows", rendered, "05:00-08:00,10:00-14:00")

// The timeline draws peak bars in a timezone and labels them with hour ticks. If the two
// ever disagree the diagram is wrong for everyone outside UTC, which is what happened:
// the bars were projected into local time while the axis was labelled in UTC, so they sat
// under the wrong numbers.
do {
    let utc = Schedule.calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 2, minute: 30))!
    for (name, tz) in [("UTC", TimeZone(identifier: "UTC")!),
                       ("UTC+4", TimeZone(secondsFromGMT: 4 * 3600)!),
                       ("UTC-5", TimeZone(secondsFromGMT: -5 * 3600)!),
                       ("UTC+5:30", TimeZone(secondsFromGMT: 5 * 3600 + 1800)!)] {
        let ranges = Schedule.localPeakRanges(for: utc, in: tz)
        let ok = !ranges.isEmpty && ranges.allSatisfy { range in
            // Every drawn bar must fall inside the local day it is drawn on.
            let cal = Calendar(identifier: .gregorian)
            var local = cal
            local.timeZone = tz
            let dayStart = local.startOfDay(for: utc)
            let dayEnd = local.date(byAdding: .day, value: 1, to: dayStart)!
            return range.end > dayStart && range.start < dayEnd
        }
        check("timeline bars inside local day (\(name))", ok ? "yes" : "no", "yes")
    }

    // Projecting must not shorten the windows: each UTC window is three or four hours.
    for (name, tz) in [("UTC+4", TimeZone(secondsFromGMT: 4 * 3600)!),
                       ("UTC-5", TimeZone(secondsFromGMT: -5 * 3600)!)] {
        let ranges = Schedule.localPeakRanges(for: utc, in: tz)
        let total = ranges.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
        check("peak hours preserved (\(name))", String(format: "%.0f", total), "7")
    }

    // A half-hour timezone must produce windows offset by 30 minutes, and both must
    // survive intact rather than getting clipped or split at the day boundary.
    //
    // Note the values: 01:00 and 06:00 UTC land on :30 in UTC+5:30, so windows start at
    // 06:30 and 11:30 IST. A naive "assert minute == 30" passes for the wrong reason.
    let kolkata = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!
    let kolkataRanges = Schedule.localPeakRanges(for: utc, in: kolkata)
    check("UTC+5:30 window count", "\(kolkataRanges.count)", "2")
    let kolkataHours = kolkataRanges.map { String(format: "%.0f", $0.end.timeIntervalSince($0.start) / 3600) }
    check("UTC+5:30 window lengths", kolkataHours.joined(separator: ","), "3,4")
    var kolkataLocal = Calendar(identifier: .gregorian)
    kolkataLocal.timeZone = kolkata
    let kolkataMinutes = kolkataRanges.map { kolkataLocal.component(.minute, from: $0.start) }
    check("UTC+5:30 windows start on the half hour",
          kolkataMinutes.allSatisfy { $0 == 30 } ? "yes" : "no", "yes")
}

// `peakState` drives the "peak resumes" line, so it has to agree with the mode.
do {
    let tuesdayPeak = Schedule.calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 2))!
    let tuesdayOff = Schedule.calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 12))!
    let saturday = Schedule.calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 2))!

    let duringPeak = Schedule.peakState(at: tuesdayPeak)
    check("peakState during peak", duringPeak.isPeakNow ? "now" : "not", "now")
    check("peakState has no nextPeak during peak", duringPeak.nextPeak == nil ? "nil" : "set", "nil")

    let duringOff = Schedule.peakState(at: tuesdayOff)
    check("peakState off-peak", duringOff.isPeakNow ? "now" : "not", "not")
    // Tuesday 12:00 UTC is past both of Tuesday's windows, so the next peak is
    // Wednesday's first one, not another window later the same day.
    check("peakState names the next window",
          duringOff.nextPeak.map { Fmt.clock($0, timeZone: Schedule.timeZone) } ?? "nil", "01:00")
    check("and it is the next day",
          duringOff.nextPeak.map { String(Schedule.calendar.component(.day, from: $0)) } ?? "nil", "9")

    // Saturday must point at Monday, since peak never runs on a weekend.
    let weekend = Schedule.peakState(at: saturday)
    let nextWeekday = weekend.nextPeak.map { Schedule.calendar.component(.weekday, from: $0) } ?? 0
    check("next peak after a Saturday is Monday", "\(nextWeekday)", "2")
}

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
