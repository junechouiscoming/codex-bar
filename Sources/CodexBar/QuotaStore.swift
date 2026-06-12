import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot = .placeholder
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var quotaAnimationID = 0
    @Published private(set) var refreshIntervalMinutes: Int

    private let service: any CodexQuotaFetching
    private var refreshTask: Task<Void, Never>?
    private let refreshIntervalKey = "dev.codexbar.refreshIntervalMinutes"
    private let allowedRefreshIntervals = [1, 5, 15, 30]

    init(service: any CodexQuotaFetching) {
        self.service = service
        let savedInterval = UserDefaults.standard.integer(forKey: refreshIntervalKey)
        refreshIntervalMinutes = allowedRefreshIntervals.contains(savedInterval) ? savedInterval : 5
    }

    func startBackgroundRefresh() {
        guard refreshTask == nil else {
            return
        }

        refreshTask = Task { [weak self] in
            await self?.refresh()

            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let interval = self.refreshIntervalMinutes
                try? await Task.sleep(for: .seconds(interval * 60))
                await self.refresh()
            }
        }
    }

    func stopBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func replayQuotaAnimation() {
        quotaAnimationID &+= 1
    }

    func setRefreshInterval(minutes: Int) {
        guard allowedRefreshIntervals.contains(minutes), refreshIntervalMinutes != minutes else {
            return
        }

        refreshIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: refreshIntervalKey)

        let wasRunning = refreshTask != nil
        stopBackgroundRefresh()
        if wasRunning {
            startBackgroundRefresh()
        }
    }

    func refresh() async {
        if isRefreshing {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let nextSnapshot = try await service.fetchQuota()
            snapshot = nextSnapshot
            errorMessage = nil
            replayQuotaAnimation()
        } catch {
            errorMessage = Self.presentableMessage(for: error)
        }
    }

    private static func presentableMessage(for error: any Error) -> String {
        if let quotaError = error as? CodexQuotaError {
            return quotaError.localizedDescription
        }

        return "刷新失败：\(error.localizedDescription)"
    }
}
