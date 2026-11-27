import Foundation

#if canImport(Security)
import Security
#endif

/// The plan-limit numbers Claude's own usage panel shows, fetched on demand. The status line only reports while a
/// terminal session is answering, so on its own it goes stale (and the Desktop app's Code tab never reports).
///
/// This reads Claude Code's OAuth login from the keychain item it created (macOS asks once to allow it), and calls
/// the same usage endpoint Claude Code's `/usage` uses. The token is only ever sent to Anthropic, never logged by
/// this app. When the login has expired it is renewed with the refresh token and written back to the same keychain item. The endpoint is not a documented API, so every failure degrades to the
/// last-known quota rather than an error wall.
public enum UsageAPI {
    public enum Failure: Error, Equatable, LocalizedError {
        case noLogin, expiredLogin, http(Int), badResponse
        public var errorDescription: String? {
            switch self {
            case .noLogin: "No Claude Code login found. Sign in with `claude` once."
            case .expiredLogin: "Claude Code's login expired. Run `claude` once to renew it."
            case .http(let c): "Usage request failed (HTTP \(c))."
            case .badResponse: "Unexpected usage response."
            }
        }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    /// Pulls the access token out of the keychain item's JSON (`claudeAiOauth.accessToken`).
    static func token(fromCredentials data: Data, now: Date = Date()) throws -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw Failure.noLogin }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0, Date(timeIntervalSince1970: ms / 1000) <= now {
            throw Failure.expiredLogin
        }
        return token
    }

    #if canImport(Security)
    static func storedCredentials() throws -> Data {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            throw Failure.noLogin
        }
        return data
    }
    #else
    static func storedCredentials() throws -> Data { throw Failure.noLogin }
    #endif

    // MARK: renewing an expired login

    /// Claude Code's public OAuth client id and token endpoints (the app renews exactly like the CLI does).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoints = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!, URL(string: "https://platform.claude.com/v1/oauth/token")!,
    ]

    /// The credentials JSON with the renewed tokens merged in. Every other field (scopes, subscription type, …) is
    /// kept as is, because Claude Code reads the very same keychain item and must keep working. The refresh token
    /// rotates, so the result must be saved before anything else happens.
    static func merged(credentials: Data, tokenResponse: Data, now: Date = Date()) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
            var oauth = root["claudeAiOauth"] as? [String: Any],
            let r = (try? JSONSerialization.jsonObject(with: tokenResponse)) as? [String: Any],
            let access = r["access_token"] as? String, !access.isEmpty
        else { return nil }
        oauth["accessToken"] = access
        if let refresh = r["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
        if let life = (r["expires_in"] as? NSNumber)?.doubleValue {
            oauth["expiresAt"] = Int((now.timeIntervalSince1970 + life) * 1000)
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    #if canImport(Security)
    static func save(credentials: Data) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        guard SecItemUpdate(q as CFDictionary, [kSecValueData as String: credentials] as CFDictionary) == errSecSuccess
        else { throw Failure.noLogin }
    }
    #else
    static func save(credentials: Data) throws { throw Failure.noLogin }
    #endif

    /// Trades the refresh token for a new access token and stores the result. Returns the new credentials.
    static func renew(_ credentials: Data, session: URLSession) async throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any], let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else { throw Failure.expiredLogin }
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
        ])
        for url in tokenEndpoints {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("claude-notch", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                let updated = merged(credentials: credentials, tokenResponse: data)
            else { continue }
            try save(credentials: updated)
            return updated
        }
        throw Failure.expiredLogin
    }

    public static func fetch(session: URLSession = .shared) async throws -> QuotaState {
        var creds = try storedCredentials()
        let token: String
        do { token = try Self.token(fromCredentials: creds) } catch Failure.expiredLogin {
            creds = try await renew(creds, session: session)
            token = try Self.token(fromCredentials: creds)
        }
        // Never answer from URLCache: the refresh button promises numbers fresh from Anthropic.
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-notch", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw code == 401 ? Failure.expiredLogin : Failure.http(code) }
        guard let q = parse(data) else { throw Failure.badResponse }
        return q
    }

    /// `{"five_hour":{"utilization":39.0,"resets_at":"2026-11-26T23:00:00.4+00:00"},"seven_day":{…},"seven_day_opus":null,…}`.
    /// Windows are discovered by key (anything `five_hour` / `seven_day…` with a utilization), like the status line's.
    public static func parse(_ data: Data, now: Date = Date()) -> QuotaState? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var windows: [QuotaWindow] = []
        for (key, value) in root where key == "five_hour" || key.hasPrefix("seven_day") {
            guard let o = value as? [String: Any], let used = (o["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(QuotaWindow(id: key, usedPercent: used, resetsAt: (o["resets_at"] as? String).flatMap(isoDate)))
        }
        guard !windows.isEmpty else { return nil }
        windows.sort { (order($0.id), $0.id) < (order($1.id), $1.id) }
        return QuotaState(windows: windows, updatedAt: now)
    }

    private static func order(_ key: String) -> Int { key == "five_hour" ? 0 : key == "seven_day" ? 1 : 2 }

    private static func isoDate(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
