import Foundation

/// Account balance, as returned by `GET https://api.deepseek.com/user/balance`.
struct AccountBalance: Codable, Equatable {
    var currency: String
    var total: Double
    var granted: Double
    var toppedUp: Double

    var isEmpty: Bool { total <= 0 }
    var grantedShare: Double { total > 0 ? granted / total : 0 }
}

enum APIError: LocalizedError {
    case missingKey
    case unauthorized
    case http(Int, String)
    case malformed(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key set"
        case .unauthorized: return "API key rejected (401)"
        case .http(let code, let body): return "HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(120))")"
        case .malformed(let s): return "Unexpected response: \(s.prefix(120))"
        case .transport(let s): return "Network: \(s)"
        }
    }
}

/// Thin client over the documented DeepSeek HTTP API.
///
/// Only account-level reads are used; the app never sends a completion request.
final class DeepSeekAPI {
    static let baseURL = URL(string: "https://api.deepseek.com")!

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = ["User-Agent": "DeepSeekBar/2.0 (macOS)"]
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func balance(apiKey: String) async throws -> AccountBalance {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.missingKey }

        let data = try await get(path: "/user/balance", apiKey: key)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed(String(data: data.prefix(200), encoding: .utf8) ?? "non-JSON")
        }
        guard let infos = obj["balance_infos"] as? [[String: Any]], let first = infos.first else {
            throw APIError.malformed("no balance_infos")
        }
        return AccountBalance(
            currency: (first["currency"] as? String) ?? "USD",
            total: Double((first["total_balance"] as? String) ?? "") ?? 0,
            granted: Double((first["granted_balance"] as? String) ?? "") ?? 0,
            toppedUp: Double((first["topped_up_balance"] as? String) ?? "") ?? 0
        )
    }

    /// Confirms the key works and returns the model ids the account can see.
    func modelIDs(apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.missingKey }
        let data = try await get(path: "/models", apiKey: key)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw APIError.malformed(String(data: data.prefix(200), encoding: .utf8) ?? "non-JSON")
        }
        return list.compactMap { $0["id"] as? String }
    }

    private func get(path: String, apiKey: String) async throws -> Data {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("no HTTP response")
            }
            switch http.statusCode {
            case 200...299:
                return data
            case 401, 403:
                throw APIError.unauthorized
            default:
                throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
}
