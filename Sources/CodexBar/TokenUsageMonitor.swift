import Foundation

struct TokenUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
}

actor TokenUsageMonitor {
    private let sessionsDirectory: URL
    private var offsetsByPath: [String: UInt64] = [:]
    private var monitorTask: Task<Void, Never>?
    private var pendingNotificationTask: Task<Void, Never>?
    private var pendingUsage: TokenUsage?
    private var onUsage: (@Sendable (TokenUsage) async -> Void)?

    init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex", directoryHint: .isDirectory)
        .appending(path: "sessions", directoryHint: .isDirectory)) {
        self.sessionsDirectory = sessionsDirectory
    }

    func start(onUsage: @escaping @Sendable (TokenUsage) async -> Void) {
        guard monitorTask == nil else {
            return
        }

        self.onUsage = onUsage
        primeOffsets()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        pendingNotificationTask?.cancel()
        pendingNotificationTask = nil
    }

    private func primeOffsets() {
        for fileURL in sessionFiles() {
            offsetsByPath[fileURL.path] = fileSize(fileURL)
        }
    }

    private func poll() {
        for fileURL in sessionFiles() {
            let path = fileURL.path
            let currentSize = fileSize(fileURL)
            let previousOffset = min(offsetsByPath[path] ?? currentSize, currentSize)
            guard currentSize > previousOffset else {
                offsetsByPath[path] = currentSize
                continue
            }

            if let data = readFile(fileURL, from: previousOffset, length: currentSize - previousOffset),
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let lineText = String(line)
                    if isUserMessage(lineText) {
                        Task {
                            await flushPendingUsage()
                        }
                    } else if let usage = parseTokenUsage(from: lineText) {
                        debounce(usage)
                    }
                }
            }

            offsetsByPath[path] = currentSize
        }
    }

    private func debounce(_ usage: TokenUsage) {
        pendingUsage = usage
        pendingNotificationTask?.cancel()
        pendingNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.flushPendingUsage()
        }
    }

    private func flushPendingUsage() async {
        guard let usage = pendingUsage else {
            return
        }

        pendingUsage = nil
        await onUsage?(usage)
    }

    private func sessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
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

    private func fileSize(_ fileURL: URL) -> UInt64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func readFile(_ fileURL: URL, from offset: UInt64, length: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }

        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    private func parseTokenUsage(from line: String) -> TokenUsage? {
        guard line.contains("\"token_count\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let inputTokens = integer(from: usage["input_tokens"]),
              let outputTokens = integer(from: usage["output_tokens"]),
              let totalTokens = integer(from: usage["total_tokens"])
        else {
            return nil
        }

        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }

    private func isUserMessage(_ line: String) -> Bool {
        guard line.contains("\"user\"") || line.contains("\"user_message\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        if let payload = root["payload"] as? [String: Any],
           payload["type"] as? String == "user_message" {
            return true
        }

        if root["type"] as? String == "response_item",
           let payload = root["payload"] as? [String: Any],
           payload["type"] as? String == "message",
           payload["role"] as? String == "user" {
            return true
        }

        return false
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
