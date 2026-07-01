import Foundation

struct QuotaSnapshot: Equatable {
    var username: String
    var displayName: String
    var avatarURL: URL?
    var planName: String
    var planExpiresAt: Date?
    var planRenewsAt: Date?
    var fiveHour: QuotaWindow
    var sevenDay: QuotaWindow
    var availableResetCount: Int?
    var resetCredits: [ResetCreditInfo]
    var monthlyTokenUsage: MonthlyTokenUsage
    var monthlyTokenUsages: [MonthlyTokenUsage]
    var fetchedAt: Date
}

struct QuotaWindow: Equatable, Identifiable {
    var id: String
    var title: String
    var remainingPercent: Double
    var resetAt: Date?

    var clampedPercent: Double {
        min(100, max(0, remainingPercent))
    }
}

struct ResetCreditInfo: Equatable, Identifiable {
    var id: String {
        [
            status ?? "",
            title ?? "",
            grantedAt.map { String($0.timeIntervalSince1970) } ?? "",
            expiresAt.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }

    var status: String?
    var title: String?
    var grantedAt: Date?
    var expiresAt: Date?
}

struct MonthlyTokenUsage: Equatable {
    var monthStart: Date
    var days: [DailyTokenUsage]
    var totalTokens: Int
    var lifetimeTokens: Int
    var peakTokens: Int

    var id: String {
        DateFormatter.codexUsageMonthID.string(from: monthStart)
    }
}

struct DailyTokenUsage: Equatable, Identifiable {
    var id: String
    var date: Date
    var tokens: Int
    var isFuture: Bool
}

extension QuotaSnapshot {
    static var placeholder: QuotaSnapshot {
        QuotaSnapshot(
            username: "Codex",
            displayName: "Codex",
            avatarURL: nil,
            planName: "Loading",
            planExpiresAt: nil,
            planRenewsAt: nil,
            fiveHour: QuotaWindow(
                id: "primary",
                title: "5小时",
                remainingPercent: 100,
                resetAt: nil
            ),
            sevenDay: QuotaWindow(
                id: "secondary",
                title: "周限额",
                remainingPercent: 100,
                resetAt: nil
            ),
            availableResetCount: nil,
            resetCredits: [],
            monthlyTokenUsage: .placeholder,
            monthlyTokenUsages: [.placeholder],
            fetchedAt: Date()
        )
    }
}

extension MonthlyTokenUsage {
    static var placeholder: MonthlyTokenUsage {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: components) ?? now
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<32
        let today = calendar.startOfDay(for: now)

        let days = dayRange.compactMap { day -> DailyTokenUsage? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else {
                return nil
            }

            return DailyTokenUsage(
                id: DateFormatter.codexUsageDayID.string(from: date),
                date: date,
                tokens: 0,
                isFuture: date >= today
            )
        }

        return MonthlyTokenUsage(
            monthStart: monthStart,
            days: days,
            totalTokens: 0,
            lifetimeTokens: 0,
            peakTokens: 0
        )
    }
}

extension DateFormatter {
    static let codexUsageMonthID: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let codexUsageDayID: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
