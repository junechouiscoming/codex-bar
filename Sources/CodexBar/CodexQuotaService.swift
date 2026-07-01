import Foundation

protocol CodexQuotaFetching: Sendable {
    func fetchQuota() async throws -> QuotaSnapshot
}

struct CodexQuotaService: CodexQuotaFetching {
    private let authStore = CodexAuthStore()
    private let tokenHistory = CodexTokenUsageHistory()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        let credentials = try await authStore.validCredentials()

        async let usage = get(
            UsageResponse.self,
            endpoint: "https://chatgpt.com/backend-api/wham/usage",
            credentials: credentials
        )

        async let profile = get(
            ProfileResponse.self,
            endpoint: "https://chatgpt.com/backend-api/wham/profiles/me",
            credentials: credentials
        )

        async let resetCredits = getOptional(
            ResetCreditsDetailResponse.self,
            endpoint: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
            credentials: credentials
        )

        async let accountCheck = getOptional(
            AccountCheckResponse.self,
            endpoint: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27",
            credentials: credentials
        )

        return try await makeSnapshot(
            usage: usage,
            profile: profile,
            resetCredits: resetCredits,
            accountCheck: accountCheck,
            credentials: credentials
        )
    }

    private func get<T: Decodable>(
        _ type: T.Type,
        endpoint: String,
        credentials: CodexCredentials
    ) async throws -> T {
        guard let url = URL(string: endpoint) else {
            throw CodexQuotaError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/0.1", forHTTPHeaderField: "User-Agent")

        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CodexQuotaError.notAuthorized
            }

            throw CodexQuotaError.backendStatus(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CodexQuotaError.decodingFailed
        }
    }

    private func getOptional<T: Decodable>(
        _ type: T.Type,
        endpoint: String,
        credentials: CodexCredentials
    ) async -> T? {
        do {
            return try await get(type, endpoint: endpoint, credentials: credentials)
        } catch {
            AppLog.write("Optional quota endpoint failed: \(endpoint), error: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeSnapshot(
        usage: UsageResponse,
        profile: ProfileResponse,
        resetCredits: ResetCreditsDetailResponse?,
        accountCheck: AccountCheckResponse?,
        credentials: CodexCredentials
    ) -> QuotaSnapshot {
        let profileInfo = profile.profile
        let fallbackName = credentials.displayName
            ?? usage.email?.components(separatedBy: "@").first
            ?? "Codex"
        let displayName = emptyToNil(profileInfo.displayName) ?? fallbackName
        let username = emptyToNil(profileInfo.username) ?? displayName
        let monthlyTokenUsages = makeMonthlyTokenUsages(from: profile.stats)
        let usageMonths = monthlyTokenUsages.isEmpty ? tokenHistory.loadRecentMonths() : monthlyTokenUsages
        let monthlyTokenUsage = usageMonths.last ?? tokenHistory.loadCurrentMonth()

        return QuotaSnapshot(
            username: username,
            displayName: displayName,
            avatarURL: profileInfo.profilePictureURL,
            planName: formatPlan(usage.planType ?? credentials.planType),
            planExpiresAt: makePlanExpiresAt(from: accountCheck),
            planRenewsAt: makePlanRenewsAt(from: accountCheck),
            fiveHour: makeWindow(
                id: "primary",
                title: "5小时",
                apiWindow: usage.rateLimit.primaryWindow
            ),
            sevenDay: makeWindow(
                id: "secondary",
                title: "周限额",
                apiWindow: usage.rateLimit.secondaryWindow
            ),
            availableResetCount: resetCredits?.availableCount ?? usage.rateLimitResetCredits?.availableCount,
            resetCredits: makeResetCredits(from: resetCredits),
            monthlyTokenUsage: monthlyTokenUsage,
            monthlyTokenUsages: usageMonths,
            fetchedAt: Date()
        )
    }

    private func makeMonthlyTokenUsages(from stats: CodexProfileStats?) -> [MonthlyTokenUsage] {
        guard let buckets = stats?.dailyUsageBuckets, !buckets.isEmpty else {
            return []
        }

        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let currentMonthStart = startOfMonth(for: now, calendar: calendar)
        var totalsByMonthAndDay: [String: [String: Int]] = [:]
        var monthStartsByID: [String: Date] = [:]

        for bucket in buckets {
            guard
                let date = DateFormatter.codexUsageDayID.date(from: bucket.startDate),
                date <= today
            else {
                continue
            }

            let monthStart = startOfMonth(for: date, calendar: calendar)
            let monthID = DateFormatter.codexUsageMonthID.string(from: monthStart)
            let id = DateFormatter.codexUsageDayID.string(from: date)
            monthStartsByID[monthID] = monthStart
            totalsByMonthAndDay[monthID, default: [:]][id, default: 0] += max(0, bucket.tokens)
        }

        let currentMonthID = DateFormatter.codexUsageMonthID.string(from: currentMonthStart)
        monthStartsByID[currentMonthID] = currentMonthStart
        let monthStarts = continuousMonthStarts(
            from: monthStartsByID.values.min() ?? currentMonthStart,
            through: currentMonthStart,
            calendar: calendar
        )

        return monthStarts
            .map { monthStart in
                makeMonthlyTokenUsage(
                    monthStart: monthStart,
                    totalsByDay: totalsByMonthAndDay[DateFormatter.codexUsageMonthID.string(from: monthStart)] ?? [:],
                    lifetimeTokens: max(0, stats?.lifetimeTokens ?? 0),
                    today: today,
                    calendar: calendar
                )
            }
    }

    private func continuousMonthStarts(from firstMonthStart: Date, through lastMonthStart: Date, calendar: Calendar) -> [Date] {
        var monthStarts: [Date] = []
        var monthStart = firstMonthStart

        while monthStart <= lastMonthStart {
            monthStarts.append(monthStart)

            guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                break
            }

            monthStart = nextMonthStart
        }

        return monthStarts
    }

    private func makeMonthlyTokenUsage(
        monthStart: Date,
        totalsByDay: [String: Int],
        lifetimeTokens: Int,
        today: Date,
        calendar: Calendar
    ) -> MonthlyTokenUsage {
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<32

        let days = dayRange.compactMap { day -> DailyTokenUsage? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else {
                return nil
            }

            let id = DateFormatter.codexUsageDayID.string(from: date)
            return DailyTokenUsage(
                id: id,
                date: date,
                tokens: totalsByDay[id, default: 0],
                isFuture: date >= today
            )
        }

        return MonthlyTokenUsage(
            monthStart: monthStart,
            days: days,
            totalTokens: days.filter { !$0.isFuture }.reduce(0) { $0 + $1.tokens },
            lifetimeTokens: lifetimeTokens,
            peakTokens: days.filter { !$0.isFuture }.map(\.tokens).max() ?? 0
        )
    }

    private func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func makeWindow(
        id: String,
        title: String,
        apiWindow: RateLimitWindowResponse
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            title: title,
            remainingPercent: 100 - apiWindow.usedPercent,
            resetAt: apiWindow.resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func makeResetCredits(from response: ResetCreditsDetailResponse?) -> [ResetCreditInfo] {
        response?.credits.map { credit in
            ResetCreditInfo(
                status: credit.status,
                title: credit.title,
                grantedAt: parseAPIDate(credit.grantedAt),
                expiresAt: parseAPIDate(credit.expiresAt)
            )
        } ?? []
    }

    private func makePlanExpiresAt(from response: AccountCheckResponse?) -> Date? {
        parseAPIDate(planEntitlement(from: response)?.expiresAt)
    }

    private func makePlanRenewsAt(from response: AccountCheckResponse?) -> Date? {
        parseAPIDate(planEntitlement(from: response)?.renewsAt)
    }

    private func planEntitlement(from response: AccountCheckResponse?) -> AccountEntitlement? {
        guard let accounts = response?.accounts else {
            return nil
        }

        return accounts["default"]?.entitlement
            ?? accounts.values.first { $0.entitlement?.hasActiveSubscription == true }?.entitlement
            ?? accounts.values.first?.entitlement
    }

    private func parseAPIDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        if let date = fractionalFormatter.date(from: value)
            ?? standardFormatter.date(from: value) {
            return date
        }

        if let timestamp = TimeInterval(value) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }

    private func formatPlan(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "Unknown"
        }

        switch value.lowercased() {
        case "plus":
            return "Plus"
        case "pro", "prolite":
            return "Pro"
        case "free":
            return "Free"
        case "team", "teams":
            return "Team"
        case "enterprise":
            return "Enterprise"
        case "self_serve_business_usage_based":
            return "Business"
        case "enterprise_cbp_usage_based":
            return "Enterprise"
        default:
            return value
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return value
    }
}

struct UsageResponse: Decodable {
    var email: String?
    var planType: String?
    var rateLimit: RateLimitResponse
    var rateLimitResetCredits: RateLimitResetCreditsResponse?
}

struct RateLimitResponse: Decodable {
    var primaryWindow: RateLimitWindowResponse
    var secondaryWindow: RateLimitWindowResponse
}

struct RateLimitWindowResponse: Decodable {
    var usedPercent: Double
    var limitWindowSeconds: Int?
    var resetAfterSeconds: Int?
    var resetAt: TimeInterval?
}

struct RateLimitResetCreditsResponse: Decodable {
    var availableCount: Int
}

struct ResetCreditsDetailResponse: Decodable {
    var availableCount: Int?
    var credits: [ResetCreditResponse]
}

struct ResetCreditResponse: Decodable {
    var status: String?
    var title: String?
    var grantedAt: String?
    var expiresAt: String?
}

struct AccountCheckResponse: Decodable {
    var accounts: [String: AccountCheckAccount]
}

struct AccountCheckAccount: Decodable {
    var entitlement: AccountEntitlement?
}

struct AccountEntitlement: Decodable {
    var hasActiveSubscription: Bool?
    var expiresAt: String?
    var renewsAt: String?
}

struct ProfileResponse: Decodable {
    var profile: CodexProfile
    var stats: CodexProfileStats?
}

struct CodexProfile: Decodable {
    var username: String?
    var displayName: String?
    var profilePictureURL: URL?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName
        case profilePictureURL = "profilePictureUrl"
    }
}

struct CodexProfileStats: Decodable {
    var dailyUsageBuckets: [CodexDailyUsageBucket]?
    var lifetimeTokens: Int?
    var peakDailyTokens: Int?
}

struct CodexDailyUsageBucket: Decodable {
    var startDate: String
    var tokens: Int
}

enum CodexQuotaError: LocalizedError {
    case authFileMissing
    case authFileUnreadable
    case authTokenMissing
    case refreshTokenMissing
    case refreshFailed
    case invalidEndpoint
    case invalidResponse
    case notAuthorized
    case backendStatus(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            return "未找到 ~/.codex/auth.json，请先运行 codex login。"
        case .authFileUnreadable:
            return "无法读取 Codex 登录信息。"
        case .authTokenMissing:
            return "Codex 登录信息里没有 access token，请重新运行 codex login。"
        case .refreshTokenMissing:
            return "登录已过期，且没有 refresh token，请重新运行 codex login。"
        case .refreshFailed:
            return "刷新 Codex 登录 token 失败，请重新运行 codex login。"
        case .invalidEndpoint:
            return "Codex 额度接口地址无效。"
        case .invalidResponse:
            return "Codex 额度接口返回了无效响应。"
        case .notAuthorized:
            return "Codex 额度接口拒绝访问，请重新运行 codex login。"
        case .backendStatus(let status):
            return "Codex 额度接口返回 HTTP \(status)。"
        case .decodingFailed:
            return "无法解析 Codex 额度接口返回的数据。"
        }
    }
}
