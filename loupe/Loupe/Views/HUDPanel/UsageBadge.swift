import SwiftUI

/// The header's usage meter: the weekly limit alone, as ten segments, one per
/// tenth of the week's allowance used (Ben, 2026-11-11: the weekly is the one
/// usage that counts). A segment fills once its tenth is reached, so 64%
/// fills six; the color follows the same bands as the popover (green under
/// 60%, orange under 85%, red above). The exact percent and the reset time
/// are in the tooltip, the full breakdown in the popover. With no cookie, no
/// reading yet, or a stale reading, the segments go gray, and a stale reading
/// adds the warning triangle.
struct UsageBadge: View {
    @EnvironmentObject var usageService: UsageService
    @State private var showPopover = false
    @Environment(\.fontScale) private var scale

    static let segmentCount = 10

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 5) {
                HStack(spacing: 2 * scale) {
                    ForEach(0..<Self.segmentCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5 * scale)
                            .fill(i < filled ? tint : Color.secondary.opacity(0.25))
                            .frame(width: 5 * scale, height: 10 * scale)
                    }
                }
                if usageService.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tooltipText)
        .popover(isPresented: $showPopover) {
            UsagePopover()
                .environmentObject(usageService)
        }
    }

    private var weekly: UsageWindow? { usageService.usage?.sevenDay }

    /// Segments filled: whole tenths of the allowance used.
    private var filled: Int {
        guard let pct = weekly?.utilization else { return 0 }
        return max(0, min(Self.segmentCount, Int(pct / 100 * Double(Self.segmentCount))))
    }

    private var tint: Color {
        guard usageService.hasCookie, let pct = weekly?.utilization else { return .secondary }
        // A number nobody has refreshed in half an hour shouldn't read as
        // authoritative, however red it is.
        guard !usageService.isStale else { return .secondary }
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    private var tooltipText: String {
        if !usageService.hasCookie {
            return "Log in to claude.ai in Arc, or set the cookie in the info popover, to enable usage tracking"
        }
        guard let u = usageService.usage else { return "Fetching usage…" }
        var parts: [String] = []
        if let wd = u.sevenDay {
            parts.append("Weekly: \(Int(wd.utilization.rounded()))% (resets \(relativeReset(wd.resetsAt)))")
        } else {
            parts.append("No weekly reading")
        }
        if usageService.isStale, let fetched = usageService.lastFetched {
            parts.append("Stale — last updated \(relative(fetched))")
        }
        parts.append("Click for the full breakdown")
        return parts.joined(separator: "\n")
    }

    private func relativeReset(_ date: Date?) -> String {
        guard let date else { return "window inactive" }
        guard date > Date() else { return "window reset" }
        return relative(date)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Full breakdown shown when the badge is clicked.
struct UsagePopover: View {
    @EnvironmentObject var usageService: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage")
                    .font(.custom("Fira Sans", size: 13).weight(.semibold))
                Spacer()
                Button(action: { Task { await usageService.refresh() } }) {
                    if usageService.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(usageService.isLoading)
                .help("Refresh now")
            }

            if !usageService.hasCookie {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No cookie configured.")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                    Text("Log in to claude.ai in Arc and the HUD reads the cookie itself, or paste your claude.ai sessionKey cookie in the info popover (i).")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let err = usageService.errorMessage, usageService.usage == nil {
                Text(err)
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let u = usageService.usage {
                VStack(alignment: .leading, spacing: 10) {
                    if let err = usageService.errorMessage, usageService.isStale {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(err)
                                .font(.custom("Fira Sans", size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
                    }
                    if let wd = u.sevenDay {
                        UsageRow(label: "Weekly (all)", window: wd)
                    }
                    perModelRows(u)
                    if let extra = u.extraUsage, extra.isEnabled {
                        Divider()
                        HStack {
                            Text("Overage")
                                .font(.custom("Fira Sans", size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let pct = extra.utilization {
                                Text("\(Int(pct.rounded()))%")
                                    .font(.custom("Fira Code", size: 11))
                            } else {
                                Text("enabled")
                                    .font(.custom("Fira Sans", size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if let fetched = usageService.lastFetched {
                        Text("Updated \(relativeString(fetched))")
                            .font(.custom("Fira Sans", size: 10))
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            } else {
                Text("Loading…")
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func relativeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Per-model weekly rows. Prefer the new `limits` array (claude.ai moved
    /// per-model usage there ~2026-07 as `weekly_scoped` entries — e.g. Fable);
    /// fall back to the legacy flat `seven_day_<model>` fields for any account
    /// still returning them.
    @ViewBuilder
    private func perModelRows(_ u: UsageResponse) -> some View {
        let scoped = (u.limits ?? []).filter { $0.kind == "weekly_scoped" }
        if !scoped.isEmpty {
            ForEach(Array(scoped.enumerated()), id: \.offset) { item in
                UsageRow(label: item.element.label,
                         window: UsageWindow(utilization: item.element.percent ?? 0,
                                             resetsAt: item.element.resetsAt))
            }
        } else {
            if let opus = u.sevenDayOpus {
                UsageRow(label: "Weekly (Opus)", window: opus)
            }
            if let sonnet = u.sevenDaySonnet {
                UsageRow(label: "Weekly (Sonnet)", window: sonnet)
            }
            if let fable = u.sevenDayFable {
                UsageRow(label: "Weekly (Fable)", window: fable)
            }
        }
    }
}

private struct UsageRow: View {
    let label: String
    let window: UsageWindow

    private var tint: Color {
        switch window.utilization {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    private var resetString: String {
        // nil = no active window yet (the API returns resets_at: null between
        // windows); a past date = stale cache from before the reset. Either
        // way "resets 23m ago" is nonsense — say what actually happened.
        guard let resetsAt = window.resetsAt else { return "no active window" }
        guard resetsAt > Date() else { return "window reset" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "resets " + formatter.localizedString(for: resetsAt, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.custom("Fira Code", size: 11).weight(.medium))
                    .foregroundColor(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: max(0, min(1, window.utilization / 100.0)) * geo.size.width, height: 4)
                }
            }
            .frame(height: 4)
            Text(resetString)
                .font(.custom("Fira Sans", size: 9))
                .foregroundColor(.secondary)
        }
    }
}
