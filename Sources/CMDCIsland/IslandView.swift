import SwiftUI

/// Reports the island's own footprint up to the panel, so the window can be
/// sized to exactly what is drawn.
private struct IslandSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The pill.
///
/// Two states, one shape. Collapsed it is a ~26pt band that reads as part of
/// the notch; expanded it is a small panel with at most three lines per
/// session. There is no third state, no card stack, and no dashboard.
///
/// Expansion is driven by hover, or by a session finishing — the two moments
/// where looking at the top of the screen should tell you something you did
/// not already know.
struct IslandView: View {

    @ObservedObject var monitor: CommandCodeMonitor
    let notch: NotchMetrics
    var onSizeChange: (CGSize) -> Void

    @State private var hovering = false
    @StateObject private var pulse = PulseClock()

    /// Written by hand rather than synthesised: `hovering` and `pulse` are
    /// private stored properties, which would make the memberwise initializer
    /// private and unusable from the panel.
    init(
        monitor: CommandCodeMonitor,
        notch: NotchMetrics,
        onSizeChange: @escaping (CGSize) -> Void
    ) {
        self.monitor = monitor
        self.notch = notch
        self.onSizeChange = onSizeChange
    }

    // MARK: - Derived

    private var spotlighted: Bool {
        Pref.expandOnFinished && monitor.spotlight != nil
    }

    private var expanded: Bool {
        (hovering && Pref.expandOnHover) || spotlighted
    }

    private var summary: CommandCodeSummary { monitor.summary }

    /// Sessions to list when open. Capped — four rows is already more than a
    /// glance can absorb, and the pill must not grow into a window.
    private var listedSessions: [CommandCodeSession] {
        if Pref.singleSessionOnly {
            return monitor.primarySession.map { [$0] } ?? []
        }
        return Array(monitor.sessions.prefix(3))
    }

    private var overflowCount: Int {
        max(0, monitor.sessions.count - listedSessions.count)
    }

    private var pulsing: Bool { summary.status == .working }

    // MARK: - Body

    var body: some View {
        content
            .background(pillBackground)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { focusPrimary() }
            .contextMenu { menu }
            .padding(.top, notch.topInset)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: IslandSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(IslandSizeKey.self) { size in
                guard size.width > 1, size.height > 1 else { return }
                onSizeChange(size)
            }
            .onAppear { syncPulse() }
            .onChange(of: summary.status) { _, _ in syncPulse() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if expanded {
                ExpandedContent(
                    summary: summary,
                    sessions: listedSessions,
                    overflow: overflowCount,
                    primary: monitor.primarySession,
                    pulseScale: pulse.scale,
                    hooksInstalled: monitor.hooksInstalled,
                    onFocus: focusPrimary
                )
                .transition(.islandContent)
            } else {
                collapsedContent
                    .transition(.islandContent)
            }
        }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            StatusDot(status: summary.status, scale: pulsing ? pulse.scale : 1)

            Text("cmd")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.primaryText)

            if let label = summary.compactLabel {
                Text(label)
                    .font(Theme.status)
                    .foregroundStyle(Theme.secondaryText)
                    .transition(.islandContent)
            }
        }
        .padding(.horizontal, Theme.Metrics.horizontalPadding)
        .frame(height: Theme.Metrics.collapsedHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: summary)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var pillBackground: some View {
        let fill = Theme.surface
        if notch.hasNotch {
            NotchShape(topRadius: 0, bottomRadius: 15)
                .fill(fill)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        } else {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let session = monitor.primarySession {
            Button("Focus \(session.displayTitle)") { focus(session) }
            Divider()
        }
        Button("Refresh") { monitor.invalidate() }
        Button("Settings…") { SettingsWindowController.shared.show() }
        Divider()
        Button("Quit CMDC Island") { NSApp.terminate(nil) }
    }

    // MARK: - Actions

    private func focusPrimary() {
        guard let session = monitor.primarySession else { return }
        focus(session)
    }

    private func focus(_ session: CommandCodeSession) {
        // Resolving a tty can spawn `ps`/`lsof`; never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalFocus.focus(session: session)
        }
    }

    private func syncPulse() {
        if pulsing { pulse.start() } else { pulse.stop() }
    }
}

// MARK: - Dot

/// The status dot. Colour carries the state; the scale pulse is reserved for
/// `working`, so movement always means "something is happening".
struct StatusDot: View {
    let status: CommandCodeStatus
    var scale: CGFloat = 1

    var body: some View {
        Circle()
            .fill(Theme.color(for: status))
            .frame(width: Theme.Metrics.dotSize, height: Theme.Metrics.dotSize)
            .scaleEffect(scale)
            .shadow(color: Theme.color(for: status).opacity(0.7), radius: 3)
    }
}

// MARK: - Expanded

/// The open pill: a header, up to three sessions, and nothing else.
private struct ExpandedContent: View {

    let summary: CommandCodeSummary
    let sessions: [CommandCodeSession]
    let overflow: Int
    let primary: CommandCodeSession?
    let pulseScale: CGFloat
    let hooksInstalled: Bool
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if sessions.isEmpty {
                emptyState
            } else {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 8)

                if sessions.count == 1, let session = sessions[0] {
                    singleSession(session)
                } else {
                    sessionList
                }
            }

            if !hooksInstalled && !sessions.isEmpty {
                hooksHint
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: Theme.Metrics.expandedWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(status: summary.status, scale: summary.status == .working ? pulseScale : 1)

            Text("Command Code")
                .font(Theme.title)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if summary.count > 1 {
                Text("\(summary.count) sessions")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            } else if Pref.showModel, let model = primary?.shortModel {
                Text(model)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Single session — the canonical shape

    private func singleSession(_ session: CommandCodeSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Indented to sit under the title, aligned past the dot.
            Text(session.subtitle)
                .font(Theme.subtitle)
                .foregroundStyle(Theme.primaryText.opacity(0.82))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Metrics.dotSize + 6)

            HStack(spacing: 5) {
                Text(session.displayPath)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text(session.status.label)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.color(for: session.status).opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.leading, Theme.Metrics.dotSize + 6)
        }
    }

    // MARK: Several sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardSpacing) {
            ForEach(sessions) { session in
                SessionRow(session: session)
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.leading, Theme.Metrics.dotSize + 6)
            }
        }
    }

    // MARK: Empty + hints

    private var emptyState: some View {
        Text("No Command Code sessions")
            .font(Theme.subtitle)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.top, 6)
            .padding(.leading, Theme.Metrics.dotSize + 6)
    }

    /// One quiet line, only when it is actionable. Hooks are what make status
    /// immediate; without them the island falls back to watching transcripts.
    private var hooksHint: some View {
        HStack(spacing: 5) {
            Text("Live status needs hooks")
                .font(Theme.detail)
                .foregroundStyle(Theme.tertiaryText)

            Spacer(minLength: 4)

            Button("Enable") {
                _ = HookInstaller.install()
                NotificationCenter.default.post(name: .hooksChanged, object: nil)
            }
            .buttonStyle(.plain)
            .font(Theme.detail)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 9)
        .padding(.leading, Theme.Metrics.dotSize + 6)
    }
}

// MARK: - Row

/// One session in a multi-session list: two lines, no more.
private struct SessionRow: View {
    let session: CommandCodeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusDot(status: session.status)

                Text(session.displayTitle)
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(session.status.label)
                    .font(Theme.detail)
                    .foregroundStyle(Theme.color(for: session.status).opacity(0.9))
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Text(session.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("·")
                    .foregroundStyle(Theme.tertiaryText)

                Text(session.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.detail)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.leading, Theme.Metrics.dotSize + 6)
        }
    }
}
