import Foundation

struct CodexCredentials: Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var displayName: String?
    var email: String?
    var planType: String?
}

struct CodexAuthStore: Sendable {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private var authFileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".codex/auth.json")
    }

    func validCredentials() async throws -> CodexCredentials {
        var credentials = try readCredentials()

        if JWT.claims(from: credentials.accessToken).expiresSoon {
            credentials = try await refresh(credentials)
        }

        return credentials
    }

    private func readCredentials() throws -> CodexCredentials {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexQuotaError.authFileMissing
        }

        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any]
        else {
            throw CodexQuotaError.authFileUnreadable
        }

        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw CodexQuotaError.authTokenMissing
        }

        let idToken = tokens["id_token"] as? String
        let accessClaims = JWT.claims(from: accessToken)
        let idClaims = idToken.map(JWT.claims(from:))
        let authClaims = accessClaims.openAIAuth ?? idClaims?.openAIAuth

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: idToken,
            accountID: tokens["account_id"] as? String ?? authClaims?["chatgpt_user_id"] as? String,
            displayName: idClaims?.string("name"),
            email: accessClaims.openAIProfile?["email"] as? String ?? idClaims?.string("email"),
            planType: authClaims?["chatgpt_plan_type"] as? String
        )
    }

    private func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw CodexQuotaError.refreshTokenMissing
        }

        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            throw CodexQuotaError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/0.1", forHTTPHeaderField: "User-Agent")

        let body = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken
        ]
        .map { key, value in
            "\(Self.formEncode(key))=\(Self.formEncode(value))"
        }
        .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexQuotaError.refreshFailed
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String
        else {
            throw CodexQuotaError.refreshFailed
        }

        try updateAuthFile(with: json)

        let idToken = json["id_token"] as? String ?? credentials.idToken
        let accessClaims = JWT.claims(from: accessToken)
        let idClaims = idToken.map(JWT.claims(from:))
        let authClaims = accessClaims.openAIAuth ?? idClaims?.openAIAuth

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
            idToken: idToken,
            accountID: credentials.accountID ?? authClaims?["chatgpt_user_id"] as? String,
            displayName: idClaims?.string("name") ?? credentials.displayName,
            email: accessClaims.openAIProfile?["email"] as? String ?? idClaims?.string("email") ?? credentials.email,
            planType: authClaims?["chatgpt_plan_type"] as? String ?? credentials.planType
        )
    }

    private func updateAuthFile(with refreshedTokens: [String: Any]) throws {
        let url = authFileURL
        let data = try Data(contentsOf: url)

        guard
            var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var tokens = root["tokens"] as? [String: Any]
        else {
            throw CodexQuotaError.authFileUnreadable
        }

        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = refreshedTokens[key] as? String {
                tokens[key] = value
            }
        }

        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct JWTClaims: Sendable {
    var payload: [String: AnySendable]

    var expiresSoon: Bool {
        guard let exp = number("exp") else {
            return false
        }

        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 120
    }

    var openAIAuth: [String: Any]? {
        payload["https://api.openai.com/auth"]?.dictionaryValue
    }

    var openAIProfile: [String: Any]? {
        payload["https://api.openai.com/profile"]?.dictionaryValue
    }

    func string(_ key: String) -> String? {
        payload[key]?.stringValue
    }

    private func number(_ key: String) -> Double? {
        payload[key]?.numberValue
    }
}

enum JWT {
    static func claims(from token: String) -> JWTClaims {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return JWTClaims(payload: [:])
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return JWTClaims(payload: [:])
        }

        return JWTClaims(payload: object.mapValues(AnySendable.init))
    }
}

struct AnySendable: @unchecked Sendable {
    let value: Any

    var stringValue: String? {
        value as? String
    }

    var numberValue: Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let int64 as Int64:
            return Double(int64)
        default:
            return nil
        }
    }

    var dictionaryValue: [String: Any]? {
        value as? [String: Any]
    }
}
