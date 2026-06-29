import AppKit
import Combine
import QuartzCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum PanelMetrics {
        static let size = NSSize(width: 440, height: 282)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = QuotaStore(service: CodexQuotaService())
    private let notificationSettings = NotificationSettings()
    private let notifier = CodexNotifier()
    private let tokenUsageMonitor = TokenUsageMonitor()
    private var panelWindow: NSWindow?
    private var statusPercent: Double?
    private var quotaNotificationTimer: Timer?
    private var lastQuotaNotificationCheckAt = Date()
    private var firedQuotaNotificationKeys = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching")
        configureApplicationIcon()
        configureStatusItem()
        configureNotifications()
        observeStore()
        observeAppearanceChanges()
        startTokenUsageMonitor()
        startQuotaResetNotificationTimer()
        store.startBackgroundRefresh()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.logStatusItemState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopBackgroundRefresh()
        quotaNotificationTimer?.invalidate()
        Task {
            await tokenUsageMonitor.stop()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationDidResignActive(_ notification: Notification) {
        hidePanel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            AppLog.write("status item has no button")
            return
        }

        statusItem.autosaveName = "dev.codexbar.CodexBar.quotaStatusItem.v2"
        statusItem.isVisible = true
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        button.toolTip = nil
        updateStatusItem(percent: nil)

        AppLog.write("status item configured")
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: iconURL) else {
            AppLog.write("application icon not found")
            return
        }

        NSApp.applicationIconImage = image
        AppLog.write("application icon configured")
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = self
        notifier.requestAuthorization()
    }

    private func startTokenUsageMonitor() {
        Task {
            await tokenUsageMonitor.start { [weak self] usage in
                await MainActor.run {
                    self?.sendTokenUsageNotification(usage)
                }
            }
        }
    }

    private func startQuotaResetNotificationTimer() {
        quotaNotificationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkQuotaResetNotifications()
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            AppLog.write("status item right clicked")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                showQuitMenu()
            }
            return
        }

        AppLog.write("status item clicked")
        if let panelWindow, panelWindow.isVisible {
            hidePanel()
        } else {
            showPanel(anchorPoint: NSEvent.mouseLocation)
        }
    }

    private func showPanel(anchorPoint: NSPoint? = nil) {
        let panel = panelWindow ?? makePanelWindow()
        positionPanel(panel, anchorPoint: anchorPoint ?? NSEvent.mouseLocation)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        setStatusHighlighted(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        AppLog.write("anchored panel shown frame=\(panel.frame.debugDescription)")
        store.replayQuotaAnimation()
    }

    private func hidePanel(animated: Bool = true) {
        guard let panel = panelWindow, panel.isVisible else {
            setStatusHighlighted(false)
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    panel?.orderOut(nil)
                    panel?.alphaValue = 1
                    self?.setStatusHighlighted(false)
                }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            setStatusHighlighted(false)
        }
    }

    private func logStatusItemState() {
        let button = statusItem.button
        let hasWindow = button?.window != nil
        let frame = button?.window?.frame.debugDescription ?? "nil"
        AppLog.write("status item state button=\(button != nil) hasWindow=\(hasWindow) windowFrame=\(frame)")
    }

    private func makePanelWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: QuotaPanelView(store: store))
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "CodexBar"
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = hostingController
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.setContentSize(PanelMetrics.size)
        panelWindow = window
        return window
    }

    private static func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            frame.intersects(screen.frame.insetBy(dx: -20, dy: -20))
        }
    }

    private func observeStore() {
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                let isPlaceholder = snapshot.planName == "Loading"
                self?.updateStatusItem(percent: isPlaceholder ? nil : snapshot.fiveHour.clampedPercent)
                self?.checkQuotaResetNotifications()
            }
            .store(in: &cancellables)
    }

    private func observeAppearanceChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func appearanceChanged() {
        updateStatusItem(percent: statusPercent)
    }

    private func updateStatusItem(percent: Double?) {
        guard let button = statusItem.button else {
            return
        }

        statusPercent = percent
        let image = StatusItemImage.make(
            percent: percent,
            usesLightArtwork: shouldUseLightStatusArtwork()
        )
        button.image = image
        button.title = ""
        statusItem.length = image.size.width + 2
    }

    private func setStatusHighlighted(_ isHighlighted: Bool) {
        statusItem.button?.highlight(false)
    }

    private func shouldUseLightStatusArtwork() -> Bool {
        guard let button = statusItem.button else {
            return true
        }

        let match = button.effectiveAppearance.bestMatch(from: [
            .darkAqua,
            .aqua,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua,
            .vibrantDark,
            .vibrantLight
        ])

        return match == .darkAqua
            || match == .accessibilityHighContrastDarkAqua
            || match == .vibrantDark
    }

    private func statusButtonFrameOnScreen() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    private func positionPanel(_ window: NSWindow, anchorPoint: NSPoint) {
        let statusFrame = statusButtonFrameOnScreen().flatMap { frame in
            Self.isFrameVisible(frame) ? frame : nil
        }
        let effectiveAnchorPoint = statusFrame.map { NSPoint(x: $0.midX, y: $0.minY) } ?? anchorPoint
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(effectiveAnchorPoint)
        } ?? NSScreen.main

        guard let screen else {
            window.center()
            return
        }

        let size = window.frame.size.width > 1 && window.frame.size.height > 1
            ? window.frame.size
            : PanelMetrics.size
        let visibleFrame = screen.visibleFrame
        let topY = statusFrame?.minY ?? visibleFrame.maxY
        let anchorX = effectiveAnchorPoint.x
        let x = min(
            max(anchorX - size.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        let y = topY - size.height - 6

        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func showQuitMenu() {
        hidePanel(animated: false)
        guard let button = statusItem.button else {
            return
        }

        let menu = NSMenu()
        let tokenItem = NSMenuItem(title: "Token 通知", action: #selector(toggleTokenNotifications), keyEquivalent: "")
        tokenItem.target = self
        tokenItem.state = notificationSettings.tokenNotificationsEnabled ? .on : .off
        menu.addItem(tokenItem)

        let quotaItem = NSMenuItem(title: "额度通知", action: #selector(toggleQuotaNotifications), keyEquivalent: "")
        quotaItem.target = self
        quotaItem.state = notificationSettings.quotaNotificationsEnabled ? .on : .off
        menu.addItem(quotaItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        setStatusHighlighted(true)
        menu.popUp(positioning: quitItem, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
        setStatusHighlighted(false)
    }

    @objc private func toggleTokenNotifications() {
        notificationSettings.tokenNotificationsEnabled.toggle()
    }

    @objc private func toggleQuotaNotifications() {
        notificationSettings.quotaNotificationsEnabled.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func sendTokenUsageNotification(_ usage: TokenUsage) {
        guard notificationSettings.tokenNotificationsEnabled else {
            return
        }

        notifier.send(
            title: "本轮回答消耗 \(tokenText(usage.totalTokens)) token",
            body: "输入 \(tokenText(usage.inputTokens)) / 输出 \(tokenText(usage.outputTokens))"
        )
    }

    private func checkQuotaResetNotifications() {
        guard notificationSettings.quotaNotificationsEnabled else {
            lastQuotaNotificationCheckAt = Date()
            return
        }

        let now = Date()
        defer { lastQuotaNotificationCheckAt = now }

        checkQuotaResetNotification(for: store.snapshot.fiveHour)
        checkQuotaResetNotification(for: store.snapshot.sevenDay)
    }

    private func checkQuotaResetNotification(for window: QuotaWindow) {
        guard let resetAt = window.resetAt else {
            return
        }

        let remaining = resetAt.timeIntervalSinceNow
        guard remaining > 0 else {
            return
        }

        for threshold in [7200, 3600, 1800, 180] {
            let thresholdValue = TimeInterval(threshold)
            let previousRemaining = resetAt.timeIntervalSince(lastQuotaNotificationCheckAt)
            guard remaining <= thresholdValue, previousRemaining > thresholdValue else {
                continue
            }

            let key = "\(window.id)-\(Int(resetAt.timeIntervalSince1970))-\(threshold)"
            guard !firedQuotaNotificationKeys.contains(key) else {
                continue
            }

            firedQuotaNotificationKeys.insert(key)
            notifier.send(
                title: "Codex额度重置通知",
                body: "\(quotaWindowName(window))距离重置还有\(quotaRemainingText(seconds: threshold))"
            )
        }
    }

    private func tokenText(_ tokens: Int) -> String {
        if tokens == 0 {
            return "0"
        }

        if tokens >= 100_000_000 {
            return compact(Double(tokens) / 100_000_000, suffix: "亿")
        }

        if tokens < 10_000 {
            return "\(tokens)"
        }

        return compact(Double(tokens) / 10_000, suffix: "万")
    }

    private func compact(_ value: Double, suffix: String) -> String {
        let text = String(format: value >= 10 ? "%.0f" : "%.1f", value)
        return text.replacingOccurrences(of: ".0", with: "") + suffix
    }

    private func quotaRemainingText(seconds: Int) -> String {
        switch seconds {
        case 7200:
            return "2小时"
        case 3600:
            return "1小时"
        case 1800:
            return "30分钟"
        case 180:
            return "3分钟"
        default:
            return "\(seconds / 60)分钟"
        }
    }

    private func quotaWindowName(_ window: QuotaWindow) -> String {
        switch window.id {
        case "primary":
            return "5小时额度"
        case "secondary":
            return "周额度"
        default:
            return "\(window.title)额度"
        }
    }
}
