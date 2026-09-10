import SwiftUI

/// The popover: one glance answers "am I being charged double right now, and what
/// have I spent?" Everything else is one click deeper.
struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    var initialTab: Tab = .rate
    var onOpenPlatform: () -> Void
    var onConnectConsole: () -> Void
    var onQuit: () -> Void

    @Environment(\.dsbOpaqueBackground) private var opaqueBackground
    @State private var tab: Tab

    enum Tab: String, CaseIterable {
        case rate = "Rate"
        case usage = "Usage"
        case settings = "Settings"
    }

    init(store: Store, settings: Settings, initialTab: Tab = .rate,
         onOpenPlatform: @escaping () -> Void,
         onConnectConsole: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.onOpenPlatform = onOpenPlatform
        self.onConnectConsole = onConnectConsole
        self.onQuit = onQuit
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            tabBar
            Group {
                if opaqueBackground {
                    // ScrollView measures to nothing under ImageRenderer, so the
                    // documentation renderer gets the content directly.
                    tabBody
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        tabBody
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                    }
                    .frame(maxHeight: 660)
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 372)
        .background(opaqueBackground ? AnyView(Color(nsColor: .windowBackgroundColor)) : AnyView(VisualEffectBackground()))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            WhaleTile(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("DeepSeek")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(store.keyStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.lastError != nil && store.balance == nil ? Palette.warning : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            ModePill(mode: store.mode)

            IconButton(systemName: "arrow.clockwise", help: "Refresh now", spinning: store.isSyncing) {
                Task { await store.sync() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases, id: \.self) { item in
                let selected = tab == item
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The selected tab's content, without any scrolling wrapper.
    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .rate: rateTab
        case .usage: usageTab
        case .settings: SettingsTab(settings: settings, store: store)
        }
    }

    // MARK: Rate tab

    private var rateTab: some View {
        VStack(spacing: 10) {
            balanceHero

            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionLabel(text: "Today's rates")
                        Spacer()
                        Text(timelineZoneLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    RateTimeline(date: store.now, timeZone: timelineZone)

                    HStack(spacing: 6) {
                        Image(systemName: store.mode == .peak ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.mode(store.mode))
                        Text(store.mode == .peak ? "Peak until" : "Off-peak until")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text("\(Fmt.clock(store.nextTransition, timeZone: timelineZone)) \(timelineZoneAbbrev)")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                        Text("· \(Fmt.countdown(store.timeUntilTransition))")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Live rates")
                        Spacer()
                        Text(Rate.flash.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    rateHeaderRow
                    rateRow("Cache hit", Fmt.money(Rate.flash.rates(for: store.mode).hit))
                    rateRow("Cache miss", Fmt.money(Rate.flash.rates(for: store.mode).miss))
                    rateRow("Output", Fmt.money(Rate.flash.rates(for: store.mode).out))

                    if settings.showSavings {
                        Divider().opacity(0.5)
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.cheap)
                            Text("Off-peak is exactly half of peak — every rate below is ×\(Int(store.mode.multiplier)) right now.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "Weekly schedule")
                    ForEach(Array(Schedule.peakWindows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.peak)
                                .frame(width: 3, height: 14)
                            Text(window.label)
                                .font(.system(size: 11.5, weight: .medium))
                                .monospacedDigit()
                            Text("UTC")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(localEquivalent(of: window))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Monday–Friday. All other hours bill at half price.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var rateHeaderRow: some View {
        HStack {
            Text("Per 1M tokens").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            Text(store.mode == .peak ? "PEAK" : "OFF-PEAK")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Palette.mode(store.mode))
        }
    }

    private func rateRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    /// "01:00–04:00 UTC" translated into the viewer's own clock.
    private func localEquivalent(of window: PeakWindow) -> String {
        guard timelineZone != Schedule.timeZone else { return "" }
        let cal = Schedule.calendar
        let today = cal.startOfDay(for: store.now)
        // Find a date in the next 7 days whose UTC weekday is a workday, then shift the window.
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard Schedule.isWorkday(weekday: weekday) else { continue }
            guard let start = cal.date(byAdding: .hour, value: window.startHour, to: day),
                  let end = cal.date(byAdding: .hour, value: window.endHour, to: day) else { continue }
            return "\(Fmt.clock(start, timeZone: timelineZone))–\(Fmt.clock(end, timeZone: timelineZone)) local"
        }
        return ""
    }

    // MARK: Balance hero

    private var balanceHero: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(text: "Balance")
                        Text(store.balance.map { Fmt.money($0.total, decimals: 2) } ?? "—")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.35), value: store.balance?.total)
                        Text(store.balanceSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        SectionLabel(text: "Spent today")
                        Text(Fmt.money(store.spentToday, decimals: 2))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(store.spentToday > 0 ? Palette.brand : .secondary)
                        Text(store.spendIsBilled ? "billed by DeepSeek" : (store.hasTrackedData ? "observed" : "no data yet"))
                            .font(.system(size: 10))
                            .foregroundStyle(store.spendIsBilled ? Palette.cheap : Color.secondary)
                    }
                }

                // Three numbers that give the balance context.
                HStack(spacing: 0) {
                    if let lifetime = store.lifetimeCost {
                        miniStat(label: "Lifetime", value: Fmt.money(lifetime, decimals: 2))
                        Divider().frame(height: 22).opacity(0.4)
                    }
                    miniStat(label: "Runway", value: runwayText, hint: runwayHint)
                    Divider().frame(height: 22).opacity(0.4)
                    miniStat(label: "Today", value: tokenSummary, hint: store.todayRequests > 0 ? nil : "no calls yet")
                }

                if let savings = store.todaySavings, settings.showSavings {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.cheap)
                        Text("Off-peak saved you \(Fmt.money(savings, decimals: 3)) today versus peak rates.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button(action: onOpenPlatform) {
                        Text("Open platform")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(ProminentCapsuleStyle())

                    IconButton(systemName: "arrow.up.right.square", help: "Top up") {
                        open("https://platform.deepseek.com/top_up")
                    }
                }
            }
        }
    }

    private func miniStat(label: String, value: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
            if let hint {
                Text(hint).font(.system(size: 8.5)).foregroundStyle(.quaternary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Explains a missing runway figure instead of leaving a bare dash.
    private var runwayHint: String? {
        guard store.balance?.total ?? 0 > 0 else { return nil }
        return runwayText == "—" ? "needs usage history" : nil
    }

    private var tokenSummary: String {
        guard store.todayRequests > 0 else { return "—" }
        return "\(Fmt.tokens(store.todayTokens.total)) tok"
    }

    private var runwayText: String {
        guard let balance = store.balance?.total, balance > 0 else { return "—" }
        defer { }
        var daily: Double?
        if let average = store.platformUsage?.averageDailyCost, average > 0.0001 {
            daily = average
        } else {
            let history = store.ledger.days.filter { $0.readCount > 1 && $0.spend > 0 }
            if !history.isEmpty {
                let recent = history.suffix(7)
                let average = recent.reduce(0) { $0 + $1.spend } / Double(recent.count)
                if average > 0.0001 { daily = average }
            }
        }
        guard let daily else { return "—" }
        return "\(max(1, Int((balance / daily).rounded()))) days"
    }

    // MARK: Usage tab

    private var usageTab: some View {
        VStack(spacing: 10) {
            if store.isConnectedToConsole {
                consoleUsage
            } else {
                connectPrompt
            }

            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "Today")
                    StatRow(label: store.spendIsBilled ? "Billed spend" : "Estimated spend",
                            value: Fmt.money(store.spentToday, decimals: 4))
                    if store.todayRequests > 0 {
                        StatRow(label: "Requests", value: Fmt.int(store.todayRequests))
                        StatRow(label: "Input · cache hit", value: Fmt.tokens(store.todayTokens.cacheHit))
                        StatRow(label: "Input · cache miss", value: Fmt.tokens(store.todayTokens.cacheMiss))
                        StatRow(label: "Output", value: Fmt.tokens(store.todayTokens.output))
                    }
                    if let rate = store.todayCacheHitRate, store.todayTokens.totalInput > 0 {
                        StatRow(label: "Cache hit rate",
                                sub: "higher is much cheaper",
                                value: String(format: "%.1f%%", rate * 100),
                                valueColor: rate > 0.8 ? Palette.cheap : .primary)
                    }
                    if !store.spendIsBilled {
                        let checks = store.today?.readCount ?? 0
                        StatRow(label: "Balance checks", sub: "estimate resolution", value: "\(checks)")
                    }
                }
            }

            if store.ledger.days.contains(where: { $0.topUp > 0 }) {
                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel(text: "Detected top-ups")
                        ForEach(store.ledger.days.filter { $0.topUp > 0 }.suffix(3).reversed(), id: \.day) { record in
                            StatRow(label: prettyDay(record.day),
                                    value: "+\(Fmt.money(record.topUp, decimals: 2))",
                                    valueColor: Palette.cheap)
                        }
                    }
                }
            }
        }
    }

    /// Billed figures straight from the console.
    private var consoleUsage: some View {
        VStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionLabel(text: "Spend · last 30 days")
                        Spacer()
                        if store.platformSyncing {
                            Text("updating…").font(.system(size: 10)).foregroundStyle(.tertiary)
                        } else {
                            Text("from DeepSeek").font(.system(size: 10)).foregroundStyle(Palette.cheap)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.money(store.platformUsage?.totalCost ?? 0, decimals: 2))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let lifetime = store.lifetimeCost {
                            Text("· \(Fmt.money(lifetime, decimals: 2)) all time")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }

                    if store.spendSeries.count > 1 {
                        SpendSparkline(series: store.spendSeries)
                    }

                    if let usage = store.platformUsage, usage.totalRequests > 0 {
                        StatRow(label: "Requests", value: Fmt.int(usage.totalRequests))
                        StatRow(label: "Tokens", value: Fmt.tokens(usage.totalTokens.total),
                                valueColor: .primary)
                        StatRow(label: "Input · cache hit", value: Fmt.tokens(usage.totalTokens.cacheHit))
                        StatRow(label: "Input · cache miss", value: Fmt.tokens(usage.totalTokens.cacheMiss))
                        StatRow(label: "Output", value: Fmt.tokens(usage.totalTokens.output))
                    }
                }
            }

            if !store.perKeyUsage.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel(text: "By API key")
                        ForEach(store.perKeyUsage.prefix(4)) { row in
                            StatRow(label: row.name,
                                    sub: "\(Fmt.int(row.requests)) requests · \(Fmt.tokens(row.tokens.total)) tokens",
                                    value: Fmt.money(row.cost, decimals: 3))
                        }
                    }
                }
            }

            if let error = store.platformError {
                Card {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.warning)
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Shown until the console session exists.
    private var connectPrompt: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Billed usage")
                Text("Connect your DeepSeek account to read real cost and token history.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.hasTrackedData {
                    Text("Until then, spend is estimated locally from balance changes.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.money(store.spentTracked, decimals: 2))
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("over \(store.trackedDayCount) day\(store.trackedDayCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if store.spendSeries.count > 1 {
                        SpendSparkline(series: store.spendSeries)
                    }
                }

                Button(action: onConnectConsole) {
                    Text("Connect account")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(ProminentCapsuleStyle())

                Text("Sign-in happens in a window on platform.deepseek.com. DeepSeekBar keeps the session so it can read your usage; nothing is sent anywhere else.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func prettyDay(_ key: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = Schedule.timeZone
        guard let date = inFmt.date(from: key) else { return key }
        let out = DateFormatter()
        out.dateFormat = "EEE d MMM"
        return out.string(from: date)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            ActionRow(systemName: "slider.horizontal.3", title: "Preferences") {
                withAnimation(.easeOut(duration: 0.16)) { tab = .settings }
            }

            Button(action: onQuit) {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 11.5, weight: .medium))
                    Text("Quit").font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Timezone helpers

    /// DeepSeek bills on UTC; show UTC to match the invoice.
    private var timelineZone: TimeZone { Schedule.timeZone }
    private var timelineZoneLabel: String { "UTC · 24h" }
    private var timelineZoneAbbrev: String { "UTC" }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Styles

struct ProminentCapsuleStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(hex: 0x6E86FF), Color(hex: 0x3D5AFE)],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.82 : (hovering ? 0.94 : 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Frosted backing that picks up the desktop behind the panel, like a system popover.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct OpaqueBackgroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true the panel paints a flat background instead of frosted glass.
    /// `ImageRenderer` cannot draw `NSVisualEffectView`, so the offscreen screenshot
    /// tool turns this on.
    var dsbOpaqueBackground: Bool {
        get { self[OpaqueBackgroundKey.self] }
        set { self[OpaqueBackgroundKey.self] = newValue }
    }
}
