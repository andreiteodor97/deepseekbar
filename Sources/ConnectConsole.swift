import SwiftUI
import WebKit

/// A real sign-in window for the DeepSeek console.
///
/// The console's API needs a browser session, and the site sits behind a bot check that
/// plain HTTP clients cannot pass. Rather than scraping credentials out of another
/// browser, the app hosts the site's own sign-in page once and keeps the resulting
/// session in its own persistent web data store — so the bot-check cookie is minted and
/// refreshed by the site's own JavaScript, exactly as in a browser.
struct ConnectConsoleWindow: View {
    var onConnected: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                WhaleTile(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connect your DeepSeek account")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Sign in once — DeepSeekBar then reads your real cost and token history.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ProgressView().controlSize(.small)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ConsoleSignInView(onSignedIn: onConnected)
        }
        .frame(width: 540, height: 660)
    }
}

/// Hosts the console's sign-in page and watches for a live session.
///
/// Success is detected by polling `localStorage.userToken` rather than by watching
/// navigation: the site is a single-page app, so the URL changes without a page load,
/// and the token appears whenever the session becomes usable — including after an
/// OAuth round trip.
struct ConsoleSignInView: NSViewRepresentable {
    var onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = PlatformAPI.userAgent
        view.load(URLRequest(url: URL(string: "https://platform.deepseek.com/sign_in")!))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onSignedIn: (String) -> Void
        private var poll: Timer?
        private var reported = false

        init(onSignedIn: @escaping (String) -> Void) {
            self.onSignedIn = onSignedIn
        }

        deinit { poll?.invalidate() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startPolling(webView)
        }

        private func startPolling(_ webView: WKWebView) {
            guard poll == nil else { return }
            let script = """
            (() => {
                try {
                    const raw = localStorage.getItem('userToken');
                    if (!raw) return '';
                    try { return (JSON.parse(raw).value) || ''; } catch (e) { return raw; }
                } catch (e) { return ''; }
            })()
            """
            let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView, !self.reported else { return }
                webView.evaluateJavaScript(script) { result, _ in
                    guard !self.reported else { return }
                    let token = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard token.count > 20 else { return }
                    self.reported = true
                    self.poll?.invalidate()
                    self.poll = nil
                    Credentials.setConsoleToken(token)
                    DispatchQueue.main.async { self.onSignedIn(token) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }
    }
}

/// Hosts the sign-in window. The menu-bar popover is far too small for a login page.
@MainActor
final class ConsoleWindowController {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(onConnected: @escaping (String) -> Void) {
        close()

        let view = ConnectConsoleWindow(
            onConnected: { [weak self] token in
                self?.close()
                onConnected(token)
            },
            onCancel: { [weak self] in self?.close() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeekBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
