import Foundation

/// Bearer credentials, kept in a 0600 JSON file under Application Support.
///
/// This deliberately does not use the keychain. Every local rebuild produces a new
/// ad-hoc signature, so the keychain treats each build as a different application and
/// prompts for the login password on every launch — unusable for a tool you rebuild.
/// A file owned by the user with mode 0600 is the same protection `gh`, `aws`, and
/// `gcloud` rely on, and it is what makes this app actually pleasant to run.
struct Credentials: Codable {
    var apiKey: String?
    /// Opaque bearer token for the console's private API, captured from a signed-in
    /// session in the app's own web view.
    var consoleToken: String?

    static let empty = Credentials()

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("DeepSeekBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("credentials.json")
    }

    static func load() -> Credentials {
        guard let data = try? Data(contentsOf: fileURL),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return .empty
        }
        return credentials
    }

    static func save(_ credentials: Credentials) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(credentials) else { return }
        let url = fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func update(_ mutate: (inout Credentials) -> Void) {
        var credentials = load()
        mutate(&credentials)
        save(credentials)
    }

    // MARK: Convenience

    static var apiKey: String { load().apiKey ?? "" }

    static var consoleToken: String? {
        let token = load().consoleToken
        return (token?.count ?? 0) > 20 ? token : nil
    }

    static func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.apiKey = trimmed.isEmpty ? nil : trimmed }
    }

    static func setConsoleToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.consoleToken = (trimmed?.count ?? 0) > 20 ? trimmed : nil }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// First-run import from tools the user already configured, so the app has something
    /// to work with before anything is typed in. Never overwrites existing values and
    /// never makes the app depend on those files.
    @discardableResult
    static func migrateFromKnownLocations() -> Bool {
        guard apiKey.isEmpty else { return false }

        let home = NSHomeDirectory()
        let candidates: [URL] = [
            URL(fileURLWithPath: home).appendingPathComponent(".codex/codex-router/deepseek-api-key.secret"),
            URL(fileURLWithPath: home).appendingPathComponent(".deepseek/api_key"),
        ]
        for url in candidates {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("sk-"), key.count > 20 {
                setAPIKey(key)
                return true
            }
        }

        // dsh keeps credentials in YAML; scan for an sk- token without parsing the file.
        let dshURL = URL(fileURLWithPath: home).appendingPathComponent(".dsh/.credentials.yaml")
        if let raw = try? String(contentsOf: dshURL, encoding: .utf8) {
            for token in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }) {
                let candidate = String(token)
                if candidate.hasPrefix("sk-"), candidate.count > 25 {
                    setAPIKey(candidate)
                    return true
                }
            }
        }
        return false
    }
}
