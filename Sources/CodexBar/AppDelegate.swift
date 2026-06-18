import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PanelMetrics {
        static let size = NSSize(width: 440, height: 282)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = QuotaStore(service: CodexQuotaService())
    private var panelWindow: NSWindow?
    private var statusPercent: Double?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching")
        configureStatusItem()
        observeStore()
        observeAppearanceChanges()
        store.startBackgroundRefresh()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.logStatusItemState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopBackgroundRefresh()
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
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        setStatusHighlighted(true)
        menu.popUp(positioning: quitItem, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
        setStatusHighlighted(false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
