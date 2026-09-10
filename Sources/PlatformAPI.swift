import Foundation
import WebKit

// MARK: - Models

/// One day of account usage as reported by the DeepSeek console.
struct UsageDay: Identifiable, Equatable {
    var date: Date
    var cost: Double
    var tokens: TokenCounts
    var requests: Int

    var id: Date { date }

    var hitRate: Double {
        let input = tokens.cacheHit + tokens.cacheMiss
        guard input > 0 else { return 0 }
        return Double(tokens.cacheHit) / Double(input)
    }

    /// What today's tokens would have cost at peak rates — the counterfactual that
    /// makes the peak/off-peak feature actionable.
    func peakEquivalentCost(card: RateCard = Rate.flash) -> Double {
        Rate.cost(tokens, card: card, mode: .peak)
    }
}

/// The account figures that only the console knows: lifetime spend and a real
/// per-day cost/token history.
struct PlatformUsage: Equatable {
    var lifetimeCost: Double?
    var lifetimeCurrency: String = "USD"
    var days: [UsageDay] = []
    var fetchedAt: Date = Date()

    func day(for date: Date, calendar: Calendar) -> UsageDay? {
        days.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    var totalCost: Double { days.reduce(0) { $0 + $1.cost } }
    var totalTokens: TokenCounts { days.reduce(TokenCounts()) { $0 + $1.tokens } }
    var totalRequests: Int { days.reduce(0) { $0 + $1.requests } }

    /// Days that actually had traffic, newest first.
    var activeDays: [UsageDay] { days.filter { $0.requests > 0 || $0.cost > 0 }.reversed() }

    var averageDailyCost: Double? {
        let active = days.filter { $0.cost > 0 }
        guard !active.isEmpty else { return nil }
        return active.reduce(0) { $0 + $1.cost } / Double(active.count)
    }
}

/// One row from the console's token table.
struct NamedTokenRow: Identifiable {
    let id: String
    let name: String
    let cost: Double
    let tokens: TokenCounts
    let requests: Int
}

// MARK: - Errors

enum PlatformError: LocalizedError {
    case notConnected
    case needsWebView
    case wafChallenge
    case invalidToken
    case app(code: Int, message: String)
    case malformed(String)
    case timedOut
    case pageFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the DeepSeek console"
        case .needsWebView: return "Console session unavailable"
        case .wafChallenge: return "Blocked by the site's bot check — reconnect to refresh"
        case .invalidToken: return "Console session expired — sign in again"
        case .app(let code, let message): return "Console error \(code): \(message)"
        case .malformed(let detail): return "Unexpected response: \(detail)"
        case .timedOut: return "The console did not respond in time"
        case .pageFailed(let detail): return "Could not load the console: \(detail)"
        }
    }
}

// MARK: - Client

/// Reads the DeepSeek console's own private API.
///
/// The console sits behind an AWS WAF challenge that plain HTTP clients cannot pass:
/// without a valid `aws-waf-token` cookie every request answers `202` with an empty
/// body. A `WKWebView` solves the challenge the same way a browser does, so requests
/// are issued *from inside* the page. The anonymous request path is intentional —
/// `fetch` defaults to `credentials: "same-origin"`, which is exactly what carries
/// the WAF cookie.
///
/// The console has no credentials of its own; the bearer token comes from the
/// credential store (see `Credentials`).
@MainActor
final class PlatformAPI: NSObject, ObservableObject {
    static let base = "https://platform.deepseek.com"
    static let origin = URL(string: base)!

    @Published private(set) var lastError: String?

    private var webView: WKWebView?
    private var hiddenWindow: NSWindow?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingTimeout: Timer?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// JavaScript that performs one console GET and posts the raw body back through
    /// the `consoleFetch` message handler. A try/catch wraps the call so transport
    /// failures come back as data instead of an opaque JavaScript error.
    private static func fetchScript(path: String, token: String) -> String {
        let escapedPath = jsEscape(path)
        let escapedToken = jsEscape(token)
        return """
        (async () => {
            const sep = String.fromCharCode(1);
            try {
                const response = await fetch("\(escapedPath)", {
                    credentials: 'same-origin',
                    headers: { 'authorization': 'Bearer \(escapedToken)', 'accept': 'application/json' }
                });
                const body = await response.text();
                window.webkit.messageHandlers.consoleFetch.postMessage(response.status + sep + body);
            } catch (error) {
                window.webkit.messageHandlers.consoleFetch.postMessage('0' + sep + String(error));
            }
        })();
        0;
        """
    }

    /// Minimal escaping for embedding a Swift string in a JavaScript literal.
    private static func jsEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: Lifecycle

    /// A web view that has cleared the bot check and is running the console's own page.
    ///
    /// The console sits behind an AWS WAF challenge. Left alone, its JavaScript solves
    /// that challenge and stores an `aws-waf-token` cookie; only then do API calls from
    /// the page return real data instead of `202 challenge`. So this waits for the page
    /// to actually render rather than trusting the first `didFinish`, which can fire on
    /// the challenge interstitial.
    private func prepare() async throws {
        if let webView, webView.url?.host()?.hasSuffix("deepseek.com") == true, !webView.isLoading,
           await hasSolvedChallenge(webView) {
            return
        }

        let view = makeWebView()
        let url = URL(string: "\(Self.base)/usage")!

        for attempt in 1...3 {
            try await load(url, in: view)
            if await hasSolvedChallenge(view) {
                try await refreshToken(from: view)
                return
            }
            // Challenge interstitials are tiny; give the scripts a moment and reload.
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
        }
        if await hasSolvedChallenge(view) {
            try await refreshToken(from: view)
            return
        }
        throw PlatformError.wafChallenge
    }

    /// The console hands the live token back in localStorage. Re-reading it keeps the
    /// keychain copy fresh and turns "signed out" into a precise error.
    private func refreshToken(from view: WKWebView) async throws {
        let script = """
        (() => {
            try {
                const raw = localStorage.getItem('userToken');
                if (!raw) return '';
                try { return (JSON.parse(raw).value) || ''; } catch (e) { return raw; }
            } catch (e) { return ''; }
        })()
        """
        let value = (try? await view.evaluateJavaScript(script) as? String) ?? ""
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > 20 else { throw PlatformError.notConnected }
        Credentials.setConsoleToken(token)
    }

    /// True once the console app itself has rendered — proof the WAF cookie is good.
    private func hasSolvedChallenge(_ view: WKWebView) async -> Bool {
        let script = "document.documentElement.outerHTML.length"
        let length = (try? await view.evaluateJavaScript(script) as? Int) ?? 0
        return length > 1500
    }

    private func load(_ url: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            view.load(URLRequest(url: url))
        }
    }

    /// A console page that must exist in a window: the bot check runs timers and layout,
    /// so an off-screen but real window behaves better than a detached web view.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "consoleFetch")

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 520, height: 360), configuration: config)
        view.navigationDelegate = self
        view.customUserAgent = Self.userAgent
        webView = view

        let host = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderBack(nil)
        hiddenWindow = host

        return view
    }

    static var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    private func teardown() {
        pendingTimeout?.invalidate()
        pendingTimeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        hiddenWindow?.orderOut(nil)
        hiddenWindow = nil
    }

    // MARK: Requests

    /// Runs `path` against the console from inside the loaded page and returns the
    /// decoded `biz_data` payload.
    private func request(path: String) async throws -> [String: Any] {
        guard let token = Credentials.consoleToken else { throw PlatformError.notConnected }

        do {
            try await prepare()
        } catch {
            teardown()
            throw error
        }

        let raw: String
        do {
            raw = try await runFetch(path: path, token: token)
        } catch {
            teardown()
            throw error
        }

        let separator = raw.firstIndex(of: "\u{0001}")
        guard let separator else {
            teardown()
            throw PlatformError.malformed("no status separator")
        }
        let statusText = String(raw[raw.startIndex..<separator])
        let body = String(raw[raw.index(after: separator)...])
        let status = Int(statusText) ?? 0

        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlatformError.malformed("status \(status), non-JSON body")
        }

        // The WAF answers a challenge with 202 and an empty body.
        if status == 202 || status == 403 {
            teardown()
            throw PlatformError.wafChallenge
        }
        let code = root["code"] as? Int ?? 0
        if code == 40003 || code == 40002 {
            teardown()
            throw PlatformError.invalidToken
        }
        if code != 0 {
            throw PlatformError.app(code: code, message: root["msg"] as? String ?? "")
        }
        guard let envelope = root["data"] as? [String: Any] else {
            throw PlatformError.malformed("no data envelope")
        }
        let bizCode = envelope["biz_code"] as? Int ?? 0
        if bizCode != 0 {
            let message = envelope["biz_msg"] as? String ?? ""
            if message == "INVALID_PARAM" { throw PlatformError.app(code: bizCode, message: message) }
            throw PlatformError.app(code: bizCode, message: message)
        }
        return envelope["biz_data"] as? [String: Any] ?? [:]
    }

    private func runFetch(path: String, token: String) async throws -> String {
        guard let webView else { throw PlatformError.needsWebView }

        let raw: String = try await withCheckedThrowingContinuation { [self] continuation in
            self.continuation = continuation
            self.pendingTimeout?.invalidate()
            self.pendingTimeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [self] _ in
                Task { @MainActor in self.failPending(PlatformError.timedOut) }
            }
            if let timer = self.pendingTimeout {
                RunLoop.main.add(timer, forMode: .common)
            }

            webView.evaluateJavaScript(Self.fetchScript(path: path, token: token)) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.failPending(PlatformError.pageFailed(error.localizedDescription))
                }
            }
        }
        return raw
    }

    private func finishPending(_ result: Result<String, Error>) {
        pendingTimeout?.invalidate()
        pendingTimeout = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        finishPending(.failure(error))
    }

    // MARK: Public reads

    /// Balances plus lifetime spend.
    func summary() async throws -> (balance: AccountBalance, lifetimeCost: Double, currency: String) {
        let payload = try await request(path: "/api/v0/users/get_user_summary")
        let normal = (payload["normal_wallets"] as? [[String: Any]])?.first
        let bonus = (payload["bonus_wallets"] as? [[String: Any]])?.first
        let lifetime = (payload["total_costs"] as? [[String: Any]])?.first

        let toppedUp = Self.decimal(normal?["balance"])
        let granted = Self.decimal(bonus?["balance"])
        let currency = (normal?["currency"] as? String) ?? "USD"

        let balance = AccountBalance(
            currency: currency,
            total: toppedUp + granted,
            granted: granted,
            toppedUp: toppedUp
        )
        return (balance, Self.decimal(lifetime?["amount"]), currency)
    }

    func invoices() async throws -> [TopUp] {
        let payload = try await request(path: "/auth-api/v0/users/get_all_invoice")
        let invoices = payload["invoices"] as? [String: Any]
        let orders = invoices?["payment_orders"] as? [[String: Any]] ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        return orders.compactMap { order in
            guard let amount = Double(order["amount"] as? String ?? "") else { return nil }
            let raw = (order["paid_at"] as? String) ?? (order["inserted_at"] as? String)
            let date = raw.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            return TopUp(
                amount: amount,
                currency: order["currency"] as? String ?? "USD",
                status: order["payment_order_status"] as? String ?? "",
                channel: order["payment_channel"] as? String ?? "",
                date: date
            )
        }
    }

    /// Cost and token history for the trailing `days` window. The console caps a window
    /// at 31 days, and only returns daily buckets for windows longer than one day.
    func usageHistory(days: Int = 30, calendar: Calendar = .current) async throws -> PlatformUsage {
        let range = try Self.window(days: days, calendar: calendar)

        let costPayload = try await request(path: "/api/v0/usage/by_api_key/cost?\(range.query)")
        let amountPayload = try await request(path: "/api/v0/usage/by_api_key/amount?\(range.query)")

        return Self.merge(cost: costPayload, amount: amountPayload, calendar: calendar, fetchedAt: Date())
    }

    /// Raw payloads, for callers that need more than the merged day totals.
    func rawCost(range: Window) async throws -> [String: Any] {
        try await request(path: "/api/v0/usage/by_api_key/cost?\(range.query)")
    }

    func rawAmount(range: Window) async throws -> [String: Any] {
        try await request(path: "/api/v0/usage/by_api_key/amount?\(range.query)")
    }

    // MARK: Range helpers

    struct Window {
        var start: Date
        var end: Date          // exclusive
        var timeZoneSeconds: Int
        var query: String
    }

    /// Builds a console-legal window: local midnights in a whole-hour timezone offset.
    static func window(days: Int, calendar: Calendar) throws -> Window {
        let clamped = max(1, min(days, 31))
        let tz = calendar.timeZone
        let offset = tz.secondsFromGMT()
        let wholeHours = Int(floor(Double(offset) / 3600.0))
        let remainder = offset - wholeHours * 3600

        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(clamped - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw PlatformError.malformed("could not build date range")
        }

        let startSeconds = Int(start.timeIntervalSince1970) - remainder
        let endSeconds = Int(end.timeIntervalSince1970) - remainder

        return Window(
            start: start, end: end, timeZoneSeconds: wholeHours * 3600,
            query: "start=\(startSeconds)&end=\(endSeconds)&tz=\(wholeHours * 3600)"
        )
    }

    // MARK: Parsing

    /// Reshapes the console's per-(key, model) series into per-day totals.
    static func merge(cost: [String: Any], amount: [String: Any], calendar: Calendar, fetchedAt: Date) -> PlatformUsage {
        var costByTime: [Int: Double] = [:]
        var lifetime: Double?
        var currency = "USD"

        do {
            let currencies = cost["data"] as? [[String: Any]] ?? []
            if let first = currencies.first, let code = first["currency"] as? String { currency = code }
            for entry in currencies {
                for series in entry["series"] as? [[String: Any]] ?? [] {
                    for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                        guard let time = bucket["time"] as? Int else { continue }
                        costByTime[time, default: 0] += decimal(bucket["cost"])
                    }
                }
            }
            if let totals = cost["total_costs"] as? [[String: Any]], let first = totals.first {
                lifetime = decimal(first["amount"])
            }
        }

        var tokensByTime: [Int: TokenCounts] = [:]
        var requestsByTime: [Int: Int] = [:]

        // `amount` may arrive as the flat series map or wrapped in the currency envelope.
        let seriesList = series(from: amount)

        for series in seriesList {
            for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                guard let time = bucket["time"] as? Int else { continue }
                let usage = bucket["usage"] as? [String: Any] ?? [:]
                let counts = TokenCounts(
                    cacheHit: UInt64(max(0, intValue(usage["PROMPT_CACHE_HIT_TOKEN"]))),
                    cacheMiss: UInt64(max(0, intValue(usage["PROMPT_CACHE_MISS_TOKEN"]))),
                    output: UInt64(max(0, intValue(usage["RESPONSE_TOKEN"])))
                )
                tokensByTime[time, default: TokenCounts()] = tokensByTime[time, default: TokenCounts()] + counts
                requestsByTime[time, default: 0] += intValue(usage["REQUEST"])
            }
        }

        let allTimes = Set(costByTime.keys).union(tokensByTime.keys).union(requestsByTime.keys)
        let days: [UsageDay] = allTimes.compactMap { time in
            let date = Date(timeIntervalSince1970: TimeInterval(time))
            return UsageDay(
                date: date,
                cost: costByTime[time] ?? 0,
                tokens: tokensByTime[time] ?? TokenCounts(),
                requests: requestsByTime[time] ?? 0
            )
        }
        .sorted { $0.date < $1.date }

        return PlatformUsage(lifetimeCost: lifetime, lifetimeCurrency: currency, days: days, fetchedAt: fetchedAt)
    }

    /// Per-key breakdown for the trailing window, for the usage table.
    static func perKey(cost: [String: Any], amount: [String: Any], calendar: Calendar) -> [NamedTokenRow] {
        var costByKey: [String: Double] = [:]
        var nameByKey: [String: String] = [:]
        var tokensByKey: [String: TokenCounts] = [:]
        var requestsByKey: [String: Int] = [:]

        do {
            for entry in cost["data"] as? [[String: Any]] ?? [] {
                for series in entry["series"] as? [[String: Any]] ?? [] {
                    let key = series["api_key"] as? [String: Any] ?? [:]
                    let id = key["tracking_id"] as? String ?? "unknown"
                    nameByKey[id] = key["name"] as? String ?? "API key"
                    for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                        costByKey[id, default: 0] += decimal(bucket["cost"])
                    }
                }
            }
        }

        let seriesList = series(from: amount)

        for series in seriesList {
            let key = series["api_key"] as? [String: Any] ?? [:]
            let id = key["tracking_id"] as? String ?? "unknown"
            if nameByKey[id] == nil { nameByKey[id] = key["name"] as? String ?? "API key" }
            for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                let usage = bucket["usage"] as? [String: Any] ?? [:]
                let counts = TokenCounts(
                    cacheHit: UInt64(max(0, intValue(usage["PROMPT_CACHE_HIT_TOKEN"]))),
                    cacheMiss: UInt64(max(0, intValue(usage["PROMPT_CACHE_MISS_TOKEN"]))),
                    output: UInt64(max(0, intValue(usage["RESPONSE_TOKEN"])))
                )
                tokensByKey[id, default: TokenCounts()] = tokensByKey[id, default: TokenCounts()] + counts
                requestsByKey[id, default: 0] += intValue(usage["REQUEST"])
            }
        }

        let ids = Set(costByKey.keys).union(tokensByKey.keys)
        return ids.map { id in
            NamedTokenRow(
                id: id,
                name: nameByKey[id] ?? "API key",
                cost: costByKey[id] ?? 0,
                tokens: tokensByKey[id] ?? TokenCounts(),
                requests: requestsByKey[id] ?? 0
            )
        }
        .sorted { $0.cost > $1.cost }
    }

    /// The `amount` endpoint returns either a flat `series` list or the currency-wrapped
    /// shape that `cost` uses. Both appear in the wild, so accept either.
    private static func series(from payload: [String: Any]) -> [[String: Any]] {
        if let flat = payload["series"] as? [[String: Any]] { return flat }
        if let wrapped = payload["data"] as? [[String: Any]] {
            return wrapped.flatMap { $0["series"] as? [[String: Any]] ?? [] }
        }
        return []
    }

    // MARK: Value coercion

    /// The console sends money as decimal strings.
    private static func decimal(_ value: Any?) -> Double {
        if let text = value as? String { return Double(text) ?? 0 }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return 0
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}

struct TopUp: Identifiable {
    var id = UUID()
    var amount: Double
    var currency: String
    var status: String
    var channel: String
    var date: Date?
}

// MARK: - JS bridge

extension PlatformAPI: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "consoleFetch", let body = message.body as? String else { return }
        finishPending(.success(body))
    }
}

// MARK: - Navigation

extension PlatformAPI: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad(.failure(PlatformError.pageFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeLoad(.failure(PlatformError.pageFailed(error.localizedDescription)))
    }

    private func resumeLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }
}
