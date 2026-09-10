import SwiftUI
import ServiceManagement

/// Everything configurable, in one column. Credentials first, since nothing else
/// matters until the app can read the account.
struct SettingsTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: Store

    @State private var keyField: String = ""
    @State private var revealKey = false
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var launchAtLogin = LaunchAgent.isInstalled

    enum TestResult {
        case ok([String])
        case failed(String)

        var text: String {
            switch self {
            case .ok(let models): return models.isEmpty ? "Connected" : "Connected · \(models.joined(separator: ", "))"
            case .failed(let message): return message
            }
        }

        var color: Color {
            switch self {
            case .ok: return Palette.cheap
            case .failed: return Palette.warning
            }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionLabel(text: "Account")
                        Spacer()
                        Text(store.keyStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 6) {
                        Group {
                            if revealKey {
                                TextField("sk-…", text: $keyField)
                            } else {
                                SecureField("sk-…", text: $keyField)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Palette.cardStroke, lineWidth: 1)
                        )

                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(revealKey ? "Hide" : "Show")
                    }

                    HStack(spacing: 8) {
                        Button {
                            Task { await saveAndTest() }
                        } label: {
                            Text(testing ? "Testing…" : "Save & test")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(ProminentCapsuleStyle())
                        .disabled(testing || keyField.trimmingCharacters(in: .whitespaces).isEmpty)

                        if !keyField.isEmpty {
                            Button("Clear") {
                                Credentials.setAPIKey("")
                                keyField = ""
                                testResult = nil
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let testResult {
                        HStack(spacing: 5) {
                            Image(systemName: testResult.color == Palette.cheap ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                            Text(testResult.text)
                                .font(.system(size: 10.5))
                                .lineLimit(2)
                        }
                        .foregroundStyle(testResult.color)
                    }

                    Text("Stored locally in Application Support with owner-only permissions. DeepSeekBar only ever makes read-only calls — it never sends a completion request.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Menu bar")
                    Picker("", selection: $settings.menuBarStyle) {
                        ForEach(Settings.MenuBarStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 12))

                    Toggle("Show the ×1 / ×2 savings note", isOn: $settings.showSavings)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    Toggle("Notify me when rates switch", isOn: $settings.notifyOnTransition)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAgent.setEnabled(newValue)
                        }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Refresh")
                    HStack(spacing: 8) {
                        Text("Every").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $settings.refreshInterval, in: 30...600, step: 30)
                        Text("\(Int(settings.refreshInterval))s")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    Text("Each refresh is one small balance request. Faster refresh means finer-grained spend tracking.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "About")
                    HStack {
                        Text("Version").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(AppInfo.version).font(.system(size: 12)).monospacedDigit()
                    }
                    HStack {
                        Text("Rates verified against").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("api-docs.deepseek.com") {
                            NSWorkspace.shared.open(URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.brand)
                    }
                    Button("Reveal data folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Storage.directory])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.brand)
                }
            }
        }
        .onAppear {
            keyField = Credentials.apiKey
        }
    }

    private func saveAndTest() async {
        testing = true
        defer { testing = false }
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        Credentials.setAPIKey(key)
        guard !key.isEmpty else {
            testResult = .failed("Enter an API key first")
            return
        }
        switch await store.testKey(key) {
        case .success(let models):
            testResult = .ok(models)
            await store.sync()
        case .failure(let error):
            testResult = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        return short
    }
}

/// Launch-at-login via a per-user LaunchAgent. Unlike `SMAppService`, this needs no
/// code signature, which matters because the app is built locally with ad-hoc signing.
enum LaunchAgent {
    static let label = "com.deepseekbar.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
