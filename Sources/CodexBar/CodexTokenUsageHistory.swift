import Foundation

struct CodexTokenUsageHistory: Sendable {
    func loadCurrentMonth() -> MonthlyTokenUsage {
        loadMonth(containing: Date())
    }

    func loadRecentMonths(limit: Int = 12) -> [MonthlyTokenUsage] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let currentMonthStart = calendar.date(from: components) ?? now
        let monthStarts = (0..<max(1, limit)).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonthStart)
        }

        let months = Array(monthStarts
            .map { loadMonth(containing: $0, calendar: calendar) }
            .reversed())
        let lifetimeTokens = months.reduce(0) { $0 + $1.totalTokens }

        return months.map { usage in
            var usage = usage
            usage.lifetimeTokens = lifetimeTokens
            return usage
        }
    }

    func loadMonth(containing date: Date) -> MonthlyTokenUsage {
        loadMonth(containing: date, calendar: Calendar.autoupdatingCurrent)
    }

    private func loadMonth(containing date: Date, calendar: Calendar) -> MonthlyTokenUsage {
        let components = calendar.dateComponents([.year, .month], from: date)
        let monthStart = calendar.date(from: components) ?? date
        let dayRange = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<32
        let today = calendar.startOfDay(for: Date())
        var totalsByDay: [String: Int] = [:]

        for fileURL in monthSessionFiles(monthStart: monthStart, calendar: calendar) {
            accumulateTokenUsage(from: fileURL, monthStart: monthStart, calendar: calendar, into: &totalsByDay)
        }

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
        let visibleDays = days.filter { !$0.isFuture }
        let totalTokens = visibleDays.reduce(0) { $0 + $1.tokens }
        let peakTokens = visibleDays.map(\.tokens).max() ?? 0

        return MonthlyTokenUsage(
            monthStart: monthStart,
            days: days,
            totalTokens: totalTokens,
            lifetimeTokens: totalTokens,
            peakTokens: peakTokens
        )
    }

    private func monthSessionFiles(monthStart: Date, calendar: Calendar) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDirectory = home.appending(path: ".codex", directoryHint: .isDirectory)
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        var files: [URL] = []

        let sessionsDirectory = codexDirectory
            .appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: year, directoryHint: .isDirectory)
            .appending(path: month, directoryHint: .isDirectory)
        files.append(contentsOf: jsonlFiles(in: sessionsDirectory))

        let archivedDirectory = codexDirectory.appending(path: "archived_sessions", directoryHint: .isDirectory)
        let archivedPrefix = "rollout-\(year)-\(month)-"
        files.append(contentsOf: jsonlFiles(in: archivedDirectory).filter { $0.lastPathComponent.hasPrefix(archivedPrefix) })

        return files
    }

    private func jsonlFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }

            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return resourceValues?.isRegularFile == true ? url : nil
        }
    }

    private func accumulateTokenUsage(
        from fileURL: URL,
        monthStart: Date,
        calendar: Calendar,
        into totalsByDay: inout [String: Int]
    ) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }

        for line in content.split(separator: "\n") where line.contains("\"token_count\"") {
            guard
                let data = String(line).data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let timestampValue = root["timestamp"] as? String,
                let timestamp = parseTimestamp(timestampValue),
                calendar.isDate(timestamp, equalTo: monthStart, toGranularity: .month),
                let payload = root["payload"] as? [String: Any],
                payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any],
                let lastUsage = info["last_token_usage"] as? [String: Any],
                let tokens = integer(from: lastUsage["total_tokens"])
            else {
                continue
            }

            let day = calendar.startOfDay(for: timestamp)
            let dayID = DateFormatter.codexUsageDayID.string(from: day)
            totalsByDay[dayID, default: 0] += tokens
        }
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatterWithFractionalSeconds.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private func integer(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }

        return nil
    }
}
