import SwiftUI

// MARK: - Surfaces

/// A grouped surface, the panel's basic building block.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.cardStroke, lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// A label/value line with the value right-aligned.
struct StatRow: View {
    let label: String
    var sub: String? = nil
    let value: String
    var valueColor: Color = .primary
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: emphasized ? .medium : .regular))
                    .foregroundStyle(emphasized ? .primary : .secondary)
                if let sub {
                    Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Mode pill

struct ModePill: View {
    let mode: PricingMode
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.mode(mode))
                .frame(width: 6, height: 6)
                .shadow(color: Palette.mode(mode).opacity(0.8), radius: 3)
            Text(mode == .peak ? "PEAK ×2" : "OFF-PEAK ×1")
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(Palette.mode(mode))
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(
            Capsule().fill(Palette.mode(mode).opacity(0.14))
        )
        .overlay(
            Capsule().strokeBorder(Palette.mode(mode).opacity(0.28), lineWidth: 0.75)
        )
        .animation(.easeInOut(duration: 0.3), value: mode)
    }
}

// MARK: - Buttons

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var spinning = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                           value: spinning)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ActionRow: View {
    let systemName: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Peak timeline

/// A 24-hour strip showing exactly when DeepSeek bills peak rates, with a live
/// "you are here" marker. Peak windows are computed in UTC and projected into the
/// selected timezone, so the strip always matches the rates actually being charged.
struct RateTimeline: View {
    let date: Date
    let timeZone: TimeZone
    var barHeight: CGFloat = 12

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Peak windows overlapping this local day, clipped and expressed as minute offsets.
    private var segments: [(start: CGFloat, end: CGFloat, label: String)] {
        let cal = calendar
        let dayStart = cal.startOfDay(for: date)
        return Schedule.localPeakRanges(for: date, in: timeZone).compactMap { range in
            let start = max(0, range.start.timeIntervalSince(dayStart) / 60)
            let end = min(1440, range.end.timeIntervalSince(dayStart) / 60)
            guard end > start else { return nil }
            return (CGFloat(start), CGFloat(end),
                    "Peak \(Fmt.clock(range.start, timeZone: timeZone))–\(Fmt.clock(range.end, timeZone: timeZone))")
        }
    }

    /// Minute offset of "now", or nil when the strip is showing a different day.
    private var nowMinute: CGFloat? {
        let cal = calendar
        let dayStart = cal.startOfDay(for: date)
        let minute = date.timeIntervalSince(dayStart) / 60
        return (minute >= 0 && minute <= 1440) ? CGFloat(minute) : nil
    }

    var body: some View {
        VStack(spacing: 4) {
            TimelineCanvas(segments: segments, nowMinute: nowMinute, barHeight: barHeight)
                .frame(height: barHeight + 6)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 8.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.quaternary)
                    if hour != 18 { Spacer() }
                }
                Text("24").font(.system(size: 8.5, weight: .medium)).monospacedDigit().foregroundStyle(.quaternary)
            }
        }
    }
}

/// Split out so `Canvas` is unambiguously SwiftUI's and the drawing maths stays in one place.
private struct TimelineCanvas: View {
    let segments: [(start: CGFloat, end: CGFloat, label: String)]
    let nowMinute: CGFloat?
    let barHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 1440

            // Off-peak base track.
            let track = Path(roundedRect: CGRect(x: 0, y: 3, width: size.width, height: barHeight),
                             cornerRadius: 4, style: .continuous)
            context.fill(track, with: .color(Palette.cheap.opacity(0.18)))

            // Peak windows.
            for segment in segments {
                let x = segment.start * scale
                let w = max(2, (segment.end - segment.start) * scale)
                let rect = CGRect(x: x, y: 3, width: w, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [Palette.peak, Palette.peak.opacity(0.78)]),
                    startPoint: CGPoint(x: x, y: 3),
                    endPoint: CGPoint(x: x, y: 3 + barHeight)
                ))
            }

            // Track outline.
            context.stroke(track, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.75)

            // Now marker.
            if let minute = nowMinute {
                let x = min(max(2, minute * scale), size.width - 2)
                var marker = Path()
                marker.addRoundedRect(in: CGRect(x: x - 1, y: 0.5, width: 2, height: barHeight + 5),
                                      cornerSize: CGSize(width: 1, height: 1))
                context.fill(marker, with: .color(Color.primary.opacity(0.85)))
            }
        }
    }
}

// MARK: - Spend sparkline

/// Observed daily spend. Deliberately understated — it is derived data, not billed data.
struct SpendSparkline: View {
    let series: [(day: String, spend: Double)]

    var body: some View {
        let maxSpend = max(series.map(\.spend).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                let fraction = item.spend / maxSpend
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(item.spend > 0 ? Palette.brand.opacity(0.35 + 0.65 * fraction) : Color.primary.opacity(0.08))
                    .frame(height: max(2, CGFloat(fraction) * 26))
                    .frame(maxWidth: .infinity)
                    .help("\(item.day): \(Fmt.money(item.spend))")
            }
        }
        .frame(height: 26, alignment: .bottom)
    }
}
