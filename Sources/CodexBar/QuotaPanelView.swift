import AppKit
import SwiftUI

struct QuotaPanelView: View {
    @ObservedObject var store: QuotaStore
    @State private var isProfileHovered = false
    @State private var isUpdateHovered = false
    @State private var isResetCreditsHovered = false
    @State private var isIntervalPickerVisible = false
    @State private var intervalDismissMonitor: Any?
    @State private var didDismissIntervalPickerFromMonitor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 7) {
                QuotaRow(window: store.snapshot.fiveHour, animationID: store.quotaAnimationID)
                QuotaRow(window: store.snapshot.sevenDay, animationID: store.quotaAnimationID)

                if let availableResetCount = store.snapshot.availableResetCount {
                    HStack {
                        Spacer(minLength: 0)

                        ResetCreditsSummary(
                            availableCount: availableResetCount,
                            credits: store.snapshot.resetCredits,
                            isHovered: $isResetCreditsHovered
                        )
                    }
                    .frame(height: 10)
                }
            }
            .zIndex(2)

            Divider()
                .opacity(0.45)

            MonthlyTokenUsageSection(usage: store.snapshot.monthlyTokenUsage)
                .zIndex(0)

            Spacer(minLength: 4)

            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 440, height: 282)
        .overlay(alignment: .bottomTrailing) {
            intervalPickerOverlay
        }
        .liquidGlassPanel(cornerRadius: 18)
        .onChange(of: isIntervalPickerVisible) { _, isVisible in
            if isVisible {
                installIntervalDismissMonitor()
            } else {
                removeIntervalDismissMonitor()
            }
        }
        .onDisappear {
            removeIntervalDismissMonitor()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ProfileAvatarView(
                    url: store.snapshot.avatarURL,
                    displayName: store.snapshot.displayName
                )

                Text(store.snapshot.displayName)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isProfileHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            .contentShape(Rectangle())
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isProfileHovered ? 0.055 : 0))
                    .padding(.horizontal, -5)
                    .padding(.vertical, -4)
            }
            .onTapGesture {
                openCodexApp()
            }
            .clickablePointer()
            .onHover { isProfileHovered = $0 }
            .help("打开 Codex")

            Spacer()

            Text(store.snapshot.planName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.08, green: 0.34, blue: 0.28))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.78, green: 0.94, blue: 0.88).opacity(0.95))
                }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 1) {
                RefreshButton(isRefreshing: store.isRefreshing) {
                    isIntervalPickerVisible = false
                    Task {
                        await store.refresh()
                    }
                }

                ZStack(alignment: .trailing) {
                    if store.errorMessage == nil {
                        updateTimeButton
                            .transition(.opacity)
                    } else {
                        Text("刷新失败，使用上次数据")
                            .id("refresh-failed")
                            .foregroundStyle(Color(red: 0.82, green: 0.16, blue: 0.13))
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .animation(.easeInOut(duration: 0.18), value: footerStatusText)
            }
            .frame(width: 110, height: 18, alignment: .trailing)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var intervalPickerOverlay: some View {
        if isIntervalPickerVisible, store.errorMessage == nil {
            RefreshIntervalPicker(
                selectedMinutes: store.refreshIntervalMinutes,
                onSelect: { minutes in
                    store.setRefreshInterval(minutes: minutes)
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isIntervalPickerVisible = false
                    }
                }
            )
            .padding(.trailing, 12)
            .padding(.bottom, 35)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            .zIndex(3)
            .animation(.easeInOut(duration: 0.16), value: isIntervalPickerVisible)
        }
    }

    private func installIntervalDismissMonitor() {
        guard intervalDismissMonitor == nil else {
            return
        }

        intervalDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            Task { @MainActor in
                didDismissIntervalPickerFromMonitor = true
                withAnimation(.easeInOut(duration: 0.14)) {
                    isIntervalPickerVisible = false
                }
                Task { @MainActor in
                    await Task.yield()
                    didDismissIntervalPickerFromMonitor = false
                }
            }
            return event
        }
    }

    private func removeIntervalDismissMonitor() {
        guard let intervalDismissMonitor else {
            return
        }

        NSEvent.removeMonitor(intervalDismissMonitor)
        self.intervalDismissMonitor = nil
    }

    private var updateTimeButton: some View {
        Text("更新于 \(refreshTimeText)")
            .id("updated-\(refreshTimeText)")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(isUpdateHovered || isIntervalPickerVisible ? 0.78 : 0.62))
            .padding(.leading, 6)
            .padding(.trailing, 0)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isUpdateHovered || isIntervalPickerVisible ? 0.055 : 0))
            }
            .contentShape(Capsule(style: .continuous))
            .onTapGesture {
                if didDismissIntervalPickerFromMonitor {
                    return
                }

                withAnimation(.easeInOut(duration: 0.16)) {
                    isIntervalPickerVisible.toggle()
                }
            }
            .clickablePointer()
            .onHover { isUpdateHovered = $0 }
            .help("设置自动刷新间隔")
    }

    private var footerStatusText: String {
        store.errorMessage == nil
            ? "更新于 \(refreshTimeText) 每\(store.refreshIntervalMinutes)分钟"
            : "刷新失败，使用上次数据"
    }

    private var refreshTimeText: String {
        let interval = Date().timeIntervalSince(store.snapshot.fetchedAt)
        guard interval >= 0, interval < 3600 else {
            return DateFormatter.codexUpdateTime.string(from: store.snapshot.fetchedAt)
        }

        if interval < 60 {
            return "刚刚"
        }

        return "\(Int(interval / 60))分钟前"
    }

    private func openCodexApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/Codex.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private struct ResetCreditsSummary: View {
    var availableCount: Int
    var credits: [ResetCreditInfo]
    @Binding var isHovered: Bool
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "info.circle")
                .font(.system(size: 8.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)

            Text("\(availableCount) 次可用重置")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
            .foregroundStyle(Color.secondary)
            .frame(width: 90, alignment: .trailing)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                ResetCreditsPopover(credits: credits)
                    .offset(y: 12)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(false)
                    .zIndex(4)
            }
            .animation(.easeInOut(duration: 0.16), value: isHovered)
            .onHover { hovering in
                if hovering {
                    showPopover()
                } else {
                    scheduleHide()
                }
            }
            .onDisappear {
                hideTask?.cancel()
            }
    }

    private func showPopover() {
        hideTask?.cancel()
        hideTask = nil

        if !isHovered {
            isHovered = true
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))

            if Task.isCancelled {
                return
            }

            isHovered = false
            hideTask = nil
        }
    }
}

private struct ResetCreditsPopover: View {
    var credits: [ResetCreditInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ResetCreditsHeader()
            if credits.isEmpty {
                Text("暂无过期时间")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(credits) { credit in
                        ResetCreditExpiryRow(credit: credit)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(width: 278, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 9, x: 0, y: 3)
        }
    }
}

private struct ResetCreditsHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("标题")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("过期时间")
                .frame(width: 102, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .foregroundStyle(.primary.opacity(0.66))
    }
}

private struct ResetCreditExpiryRow: View {
    var credit: ResetCreditInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(credit.title ?? "--")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(DateFormatter.codexResetCreditMinute.stringOrPlaceholder(from: credit.expiresAt))
                .frame(width: 102, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
    }
}

struct RefreshButton: View {
    var isRefreshing: Bool
    var action: () -> Void

    @State private var rotation = 0.0
    @State private var shouldSpin = false
    @State private var spinTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 16, height: 18)
            .rotationEffect(.degrees(rotation))
            .foregroundStyle(.secondary)
            .opacity(isRefreshing ? 0.78 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRefreshing else {
                    return
                }

                action()
            }
            .clickablePointer()
            .help("手动刷新")
            .onChange(of: isRefreshing) { _, isRefreshing in
                if isRefreshing {
                    startSpinning()
                } else {
                    shouldSpin = false
                }
            }
            .onDisappear {
                spinTask?.cancel()
            }
    }

    private func startSpinning() {
        shouldSpin = true
        guard spinTask == nil else {
            return
        }

        spinTask = Task { @MainActor in
            var step = 0
            while shouldSpin || step != 0 {
                if Task.isCancelled {
                    spinTask = nil
                    return
                }

                try? await Task.sleep(for: .milliseconds(28))
                if Task.isCancelled {
                    spinTask = nil
                    return
                }

                step = (step + 1) % 24
                withAnimation(.linear(duration: 0.028)) {
                    rotation += 15
                }
            }

            rotation.formTruncatingRemainder(dividingBy: 360)
            spinTask = nil
        }
    }
}

struct RefreshIntervalPicker: View {
    var selectedMinutes: Int
    var onSelect: (Int) -> Void

    private let options = [1, 5, 15, 30]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { minutes in
                intervalOption(minutes)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 9, x: 0, y: 3)
        }
    }

    private func intervalOption(_ minutes: Int) -> some View {
        let isSelected = selectedMinutes == minutes

        return Text("\(minutes)分")
            .font(.system(size: 10.5, weight: isSelected ? .bold : .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color(red: 0.10, green: 0.38, blue: 0.31) : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? Color(red: 0.78, green: 0.94, blue: 0.88).opacity(0.95) : Color.primary.opacity(0.045))
            }
            .contentShape(Capsule(style: .continuous))
            .onTapGesture {
                onSelect(minutes)
            }
            .clickablePointer()
    }
}

struct ProfileAvatarView: View {
    var url: URL?
    var displayName: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.secondary.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "person.circle")
            .font(.system(size: 18, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.secondary.opacity(0.78))
            .accessibilityLabel(displayName)
    }
}

struct QuotaRow: View {
    var window: QuotaWindow
    var animationID: Int
    @State private var displayedPercent: Double = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(window.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 44, alignment: .leading)

            SegmentedQuotaBar(percent: displayedPercent, fillColor: targetBarColor)
                .frame(height: 15)

            Text("\(Int(displayedPercent.rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(targetBarColor)
                .frame(width: 40, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: 18)
        .onAppear {
            replayAnimation()
        }
        .onChange(of: animationID) {
            replayAnimation()
        }
        .onDisappear {
            animationTask?.cancel()
        }
    }

    private var resetText: String {
        guard let resetAt = window.resetAt else {
            return "--:--"
        }

        if Calendar.autoupdatingCurrent.isDateInToday(resetAt) {
            return "\(DateFormatter.codexResetTime.string(from: resetAt))重置"
        }

        return "\(DateFormatter.codexResetDate.string(from: resetAt))重置"
    }

    private var targetBarColor: Color {
        QuotaColor.color(for: window.clampedPercent)
    }

    private func replayAnimation() {
        let targetPercent = window.clampedPercent
        animationTask?.cancel()
        displayedPercent = 0

        animationTask = Task { @MainActor in
            let steps = SegmentedQuotaBar.segmentCount
            for step in 1...steps {
                if Task.isCancelled {
                    return
                }

                try? await Task.sleep(for: .milliseconds(42))

                if Task.isCancelled {
                    return
                }

                withAnimation(.easeOut(duration: 0.16)) {
                    displayedPercent = targetPercent * Double(step) / Double(steps)
                }
            }

            displayedPercent = targetPercent
        }
    }
}

struct MonthlyTokenUsageSection: View {
    var usage: MonthlyTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    UsageMetric(title: "昨日使用", value: tokenText(yesterdayTokens))
                    UsageMetric(title: "本月日均", value: tokenText(averageDailyTokens))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    UsageMetric(title: "当月累计", value: tokenText(usage.totalTokens), alignment: .trailing)
                    UsageMetric(title: "总累计", value: tokenText(usage.lifetimeTokens), alignment: .trailing)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(DateFormatter.codexUsageMonthTitle.string(from: usage.monthStart))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("每日 token")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            TokenUsageStrip(usage: usage)
                .frame(height: 46)
        }
    }

    private var yesterdayTokens: Int {
        let calendar = Calendar.autoupdatingCurrent
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else {
            return 0
        }

        return usage.days.first { calendar.isDate($0.date, inSameDayAs: yesterday) }?.tokens ?? 0
    }

    private var averageDailyTokens: Int {
        let visibleDays = usage.days.filter { !$0.isFuture }
        guard !visibleDays.isEmpty else {
            return 0
        }

        return Int((Double(usage.totalTokens) / Double(visibleDays.count)).rounded())
    }

    private func tokenText(_ tokens: Int) -> String {
        if tokens == 0 {
            return "0"
        }

        if tokens >= 100_000_000 {
            return compact(Double(tokens) / 100_000_000, suffix: "亿")
        }

        return compact(Double(tokens) / 10_000, suffix: "万")
    }

    private func compact(_ value: Double, suffix: String) -> String {
        let text = String(format: value >= 10 ? "%.0f" : "%.1f", value)
        return text.replacingOccurrences(of: ".0", with: "") + suffix
    }
}

struct UsageMetric: View {
    var title: String
    var value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

struct TokenUsageStrip: View {
    var usage: MonthlyTokenUsage
    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let days = usage.days
            let gap: CGFloat = 3
            let width = max(4, (proxy.size.width - gap * CGFloat(max(days.count - 1, 0))) / CGFloat(max(days.count, 1)))

            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(Color.primary.opacity(day.isFuture ? 0.025 : 0.045))
                                .frame(width: width, height: proxy.size.height)

                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(barColor(for: day))
                                .frame(width: width, height: barHeight(for: day, in: proxy.size.height))
                        }
                        .frame(width: width, height: proxy.size.height, alignment: .bottom)
                        .opacity(day.isFuture ? 0.5 : 1)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            withAnimation(.easeInOut(duration: 0.12)) {
                                hoveredIndex = isHovering && !day.isFuture ? index : nil
                            }
                        }
                        .animation(.easeOut(duration: 0.18), value: day.tokens)
                    }
                }

                if let hoveredIndex, days.indices.contains(hoveredIndex), !days[hoveredIndex].isFuture {
                    let tooltipWidth: CGFloat = min(proxy.size.width, 232)
                    let rawX = CGFloat(hoveredIndex) * (width + gap) + width / 2 - tooltipWidth / 2
                    let x = min(max(0, rawX), max(0, proxy.size.width - tooltipWidth))

                    Text(tooltip(for: days[hoveredIndex]))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(width: tooltipWidth)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
                        }
                        .offset(x: x, y: -32)
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
        }
    }

    private func tooltip(for day: DailyTokenUsage) -> String {
        let date = DateFormatter.codexUsageTooltipDate.string(from: day.date)
        let tokens = tokenText(day.tokens)
        return "\(date)：已使用 \(tokens) token"
    }

    private func tokenText(_ tokens: Int) -> String {
        if tokens == 0 {
            return "0"
        }

        if tokens >= 100_000_000 {
            return compact(Double(tokens) / 100_000_000, suffix: "亿")
        }

        return compact(Double(tokens) / 10_000, suffix: "万")
    }

    private func compact(_ value: Double, suffix: String) -> String {
        let text = String(format: value >= 10 ? "%.0f" : "%.1f", value)
        return text.replacingOccurrences(of: ".0", with: "") + suffix
    }

    private func barHeight(for day: DailyTokenUsage, in availableHeight: CGFloat) -> CGFloat {
        guard !day.isFuture else {
            return 0
        }

        guard day.tokens > 0, usage.peakTokens > 0 else {
            return max(3, availableHeight * 0.16)
        }

        let ratio = min(1, Double(day.tokens) / Double(usage.peakTokens))
        return max(4, availableHeight * CGFloat(0.18 + ratio * 0.82))
    }

    private func barColor(for day: DailyTokenUsage) -> Color {
        if day.isFuture {
            return .clear
        }

        guard day.tokens > 0, usage.peakTokens > 0 else {
            return Color(red: 0.78, green: 0.86, blue: 0.96).opacity(0.5)
        }

        let ratio = min(1, Double(day.tokens) / Double(usage.peakTokens))
        return Color(red: 0.20, green: 0.48, blue: 0.86).opacity(0.38 + ratio * 0.62)
    }
}

private extension View {
    func clickablePointer() -> some View {
        modifier(ClickablePointerModifier())
    }

    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background {
                    VisualEffectBackdrop(material: .popover, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .opacity(0.78)
                }
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                }
        } else {
            self
                .background {
                    VisualEffectBackdrop(material: .popover, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .opacity(0.78)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                        }
                }
        }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

private struct ClickablePointerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

struct SegmentedQuotaBar: View {
    var percent: Double
    var fillColor: Color
    static let segmentCount = 20

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 4
            let width = max(4, (proxy.size.width - spacing * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount))
            let filledCount = Int((percent / 100 * Double(Self.segmentCount)).rounded(.toNearestOrAwayFromZero))

            HStack(spacing: spacing) {
                ForEach(0..<Self.segmentCount, id: \.self) { index in
                    ZStack {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))

                        if index < filledCount {
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(fillColor)
                                .overlay {
                                    LinearGradient(
                                        colors: [.white.opacity(0.24), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                                }
                                .transition(
                                    .asymmetric(
                                        insertion: .quotaTileSqueezeIn,
                                        removal: .opacity
                                    )
                                )
                        }
                    }
                    .frame(width: width, height: proxy.size.height)
                    .clipped()
                }
            }
            .animation(.easeOut(duration: 0.16), value: filledCount)
        }
    }
}

private struct QuotaTileSqueezeInModifier: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(x: max(0.08, progress), y: 1, anchor: .leading)
            .brightness((1 - progress) * 0.04)
    }
}

private extension AnyTransition {
    static var quotaTileSqueezeIn: AnyTransition {
        .modifier(
            active: QuotaTileSqueezeInModifier(progress: 0),
            identity: QuotaTileSqueezeInModifier(progress: 1)
        )
    }
}

enum QuotaColor {
    static func color(for percent: Double) -> Color {
        switch percent {
        case 0...30:
            return Color(red: 0.91, green: 0.27, blue: 0.22)
        case 31...60:
            return Color(red: 0.93, green: 0.66, blue: 0.18)
        default:
            return Color(red: 0.16, green: 0.63, blue: 0.43)
        }
    }
}

extension DateFormatter {
    static let codexResetTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let codexResetDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let codexUpdateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let codexUsageMonthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M月"
        return formatter
    }()

    static let codexUsageTooltipDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let codexResetCredit: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let codexResetCreditMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    func stringOrPlaceholder(from date: Date?) -> String {
        guard let date else {
            return "--"
        }

        return string(from: date)
    }
}
