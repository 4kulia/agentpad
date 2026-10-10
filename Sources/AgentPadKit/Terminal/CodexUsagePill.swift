import SwiftUI

/// Status-bar gauge for Codex account rate limits. Codex writes the 5-hour and
/// weekly window usage into its rollout file after every turn (parsed by
/// `CodexUsageMonitor` into `Session.codexUsage`). The gauge shows the
/// **remaining** percentage of each window — matching what the Codex client
/// itself displays, so the number reads the same in both — colored by how
/// little is left, with a click-through detail popover. Shape/styling mirror
/// `ToolCallActivityPill`. (The raw `CodexUsage` stays `used_percent` as Codex
/// reports it; the inversion to "remaining" happens only here at display.)
struct CodexUsagePill: View {
    let usage: CodexUsage
    @State private var detailOpen = false
    @State private var isHovered = false

    var body: some View {
        Button { detailOpen = true } label: {
            pillContent
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(fill)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(Theme.chromeTransition, value: detailOpen)
        .attentionPopover(isPresented: $detailOpen, arrowEdge: .top) {
            CodexUsageDetailPopover(usage: usage)
        }
        .help(String(localized: "Codex usage remaining", bundle: .agentPadResources))
        .accessibilityLabel(accessibilityLabel)
    }

    /// Widest variant that fits: both windows → most-constrained window (least
    /// remaining) with label → icon + that percentage. `.fixedSize` on the
    /// chips makes each variant's ideal width reflect its real content so
    /// `ViewThatFits` picks correctly.
    @ViewBuilder
    private var pillContent: some View {
        let windows = presentWindows
        ViewThatFits(in: .horizontal) {
            fullPill(windows)
            compactPill(windows)
            iconOnlyPill(windows)
        }
    }

    private func fullPill(_ windows: [Window]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            gauge
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                if index > 0 { separator }
                windowChip(window)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    /// The most-constrained window (least remaining) — the one a narrow pill
    /// surfaces when it can't fit both.
    private func tightest(_ windows: [Window]) -> Window? {
        windows.min(by: { $0.remaining < $1.remaining })
    }

    private func compactPill(_ windows: [Window]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            gauge
            if let window = tightest(windows) {
                windowChip(window)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func iconOnlyPill(_ windows: [Window]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            gauge
            if let window = tightest(windows) {
                Text(Self.percentText(window.remaining))
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Self.color(forRemaining: window.remaining))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func windowChip(_ window: Window) -> some View {
        HStack(spacing: 3) {
            Text(window.label)
                .foregroundStyle(Theme.chromeMuted)
            Text(Self.percentText(window.remaining))
                .foregroundStyle(Self.color(forRemaining: window.remaining))
        }
        .font(Theme.mono(11, weight: .regular))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var gauge: some View {
        Image(systemName: "gauge.medium")
            .imageScale(.small)
            .foregroundStyle(Theme.chromeMuted)
    }

    private var fill: Color {
        if detailOpen { return Theme.chromeActive }
        if isHovered { return Theme.chromeActive }
        return Theme.chromeHover
    }

    private var separator: some View {
        Text("·").foregroundStyle(Theme.chromeFaint)
    }

    // MARK: - Window model

    /// One rate-limit window flattened for display (only the present ones).
    /// `remaining` is `100 − used_percent` — what the gauge shows.
    struct Window {
        let label: String
        let remaining: Double
        let resetsAt: Date?
    }

    private var presentWindows: [Window] {
        var windows: [Window] = []
        if let p = usage.primaryUsedPercent {
            windows.append(Window(label: Self.windowLabel(usage.primaryWindowMinutes) ?? "5h",
                                  remaining: Self.remaining(p), resetsAt: usage.primaryResetsAt))
        }
        if let s = usage.secondaryUsedPercent {
            windows.append(Window(label: Self.windowLabel(usage.secondaryWindowMinutes) ?? "7d",
                                  remaining: Self.remaining(s), resetsAt: usage.secondaryResetsAt))
        }
        return windows
    }

    private var accessibilityLabel: String {
        presentWindows.map {
            String.localizedStringWithFormat(
                String(localized: "%@ %@ left", bundle: .agentPadResources),
                $0.label,
                Self.percentText($0.remaining)
            )
        }.joined(separator: ", ")
    }

    // MARK: - Pure formatters (also used by the popover + tests)

    /// Labels a window by its length: 300min → "5h", 10080min → "7d".
    static func windowLabel(_ minutes: Int?) -> String? {
        guard let m = minutes, m > 0 else { return nil }
        if m % 1440 == 0 { return "\(m / 1440)d" }
        if m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }

    static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// `100 − used`, clamped to 0–100 (Codex reports `used_percent`; the gauge
    /// shows what's left).
    static func remaining(_ usedPercent: Double) -> Double {
        min(max(100 - usedPercent, 0), 100)
    }

    /// Severity ramp on *remaining*: red when almost out (≤10% left), amber
    /// when low (≤25%), normal otherwise.
    static func color(forRemaining remaining: Double) -> Color {
        if remaining <= 10 { return Theme.activityFailure }
        if remaining <= 25 { return Theme.activityAttention }
        return Theme.chromeForeground
    }

    /// "resets in 3h 12m" / "resets in 2d 4h" / "resets now". `nil` when no
    /// reset timestamp was reported.
    static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "resets now" }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 { return "resets in \(totalMinutes)m" }
        let hours = totalMinutes / 60
        if hours < 24 { return "resets in \(hours)h \(totalMinutes % 60)m" }
        let days = hours / 24
        return "resets in \(days)d \(hours % 24)h"
    }

    /// Fixed system-prompt + tool-definition overhead Codex discounts from the
    /// context window before computing the percentage (`BASELINE_TOKENS` in
    /// codex's protocol.rs).
    static let contextBaselineTokens = 12000

    /// Context-window % used, computed exactly like the Codex client so the
    /// number matches what it shows: it discounts a fixed ~12k baseline from
    /// both the used tokens and the window, then truncates (codex casts an f32
    /// to u8). Returns 0–100. (Codex internally tracks "percent remaining"; we
    /// return `100 − remaining` since it displays "% used".)
    static func contextUsedPercent(used: Int, window: Int) -> Int {
        let baseline = contextBaselineTokens
        guard window > baseline else { return 0 }
        let effective = window - baseline
        let usedAdjusted = max(used - baseline, 0)
        let remaining = max(effective - usedAdjusted, 0)
        let remainingPercent = min(100, Int(Double(remaining) / Double(effective) * 100))
        return 100 - remainingPercent
    }

    static func tokensText(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }
}

/// Click-through detail for the Codex usage gauge: each window as a labeled
/// bar with its reset countdown, plus the plan tier and session token total.
private struct CodexUsageDetailPopover: View {
    let usage: CodexUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AgentIconView(asset: AgentTemplate.codex.iconAsset, fallbackSymbol: "chevron.left.forwardslash.chevron.right", size: 16)
                Text(String(localized: "usage remaining", bundle: .agentPadResources))
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                Spacer()
                if let plan = usage.planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(Theme.mono(9, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(Theme.chromeMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.chromeFaint, lineWidth: 1))
                }
            }

            // Tick the reset countdowns once a minute while the popover stays
            // open — otherwise "resets in 3h 12m" freezes at first-render time.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 14) {
                    if let p = usage.primaryUsedPercent {
                        windowRow(title: usage.primaryWindowMinutes.flatMap(CodexUsagePill.windowLabel).map {
                            String.localizedStringWithFormat(
                                String(localized: "%@ window", bundle: .agentPadResources),
                                $0
                            )
                        } ?? String(localized: "5h window", bundle: .agentPadResources),
                                  remaining: CodexUsagePill.remaining(p), resetsAt: usage.primaryResetsAt, now: context.date)
                    }
                    if let s = usage.secondaryUsedPercent {
                        windowRow(title: usage.secondaryWindowMinutes.flatMap(CodexUsagePill.windowLabel).map {
                            String.localizedStringWithFormat(
                                String(localized: "%@ window", bundle: .agentPadResources),
                                $0
                            )
                        } ?? String(localized: "7d window", bundle: .agentPadResources),
                                  remaining: CodexUsagePill.remaining(s), resetsAt: usage.secondaryResetsAt, now: context.date)
                    }
                }
            }

            if let used = usage.contextUsedTokens {
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
                contextRow(used: used, total: usage.contextWindow)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .background(Theme.chromeBackground)
    }

    /// Context-window occupancy. The headline is the **% used**, computed the
    /// Codex way (baseline-discounted) so it matches the Codex client; the raw
    /// token counts are a caption for absolute scale (they won't naively divide
    /// to the %, by design — Codex discounts the ~12k system-prompt baseline).
    /// The fill uses the neutral info accent (blue) — distinct from the
    /// red/amber rate-limit bars, since a filling context is normal.
    private func contextRow(used: Int, total: Int?) -> some View {
        let percent = total.map { CodexUsagePill.contextUsedPercent(used: used, window: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "context window", bundle: .agentPadResources))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                Spacer()
                if let percent {
                    Text("\(percent)%")
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                    Text(String(localized: "used", bundle: .agentPadResources))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.chromeMuted)
                }
            }
            if let percent {
                UsageBar(percent: Double(percent), color: Theme.activityRunning)
            }
            Text(total.map {
                String.localizedStringWithFormat(
                    String(localized: "%@ / %@ tokens", bundle: .agentPadResources),
                    CodexUsagePill.tokensText(used),
                    CodexUsagePill.tokensText($0)
                )
            } ?? String.localizedStringWithFormat(
                String(localized: "%@ tokens", bundle: .agentPadResources),
                CodexUsagePill.tokensText(used)
            ))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.chromeMuted)
        }
    }

    private func windowRow(title: String, remaining: Double, resetsAt: Date?, now: Date) -> some View {
        let color = CodexUsagePill.color(forRemaining: remaining)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                Spacer()
                Text(CodexUsagePill.percentText(remaining))
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(color)
                Text(String(localized: "left", bundle: .agentPadResources))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.chromeMuted)
            }
            UsageBar(percent: remaining, color: color)
            if let reset = CodexUsagePill.resetText(resetsAt, now: now) {
                Text(reset)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted)
            }
        }
    }

}

/// Thin capsule progress bar, clamped to 0–100%.
private struct UsageBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chromeFaint.opacity(0.5))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 5)
    }
}
