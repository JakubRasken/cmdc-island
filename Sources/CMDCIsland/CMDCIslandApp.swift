import SwiftUI

@main
struct CMDCIslandApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var monitor = CommandCodeMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(monitor: monitor)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    /// A menu-bar glyph that mirrors the island's state. Kept to symbols that
    /// have shipped for years so the item is never blank.
    private var menuBarSymbol: String {
        guard !monitor.summary.isEmpty else { return "terminal" }
        switch monitor.summary.status {
        case .working:   return "circle.fill"
        case .waiting:   return "circle"
        case .completed: return "checkmark.circle.fill"
        case .idle:      return "circle"
        case .unknown:   return "questionmark.circle"
        }
    }
}

// MARK: - Menu

private struct MenuBarContent: View {
    @ObservedObject var monitor: CommandCodeMonitor

    var body: some View {
        if monitor.sessions.isEmpty {
            Text("No Command Code sessions")
        } else {
            ForEach(monitor.sessions) { session in
                Button {
                    TerminalFocus.focus(session: session)
                } label: {
                    Text("\(mark(session.status))  \(session.displayTitle) — \(session.status.label)")
                }
            }
        }

        Divider()

        Button("Refresh") { monitor.invalidate() }

        if !monitor.hooksInstalled {
            Button("Install Command Code hooks…") {
                _ = HookInstaller.install()
                NotificationCenter.default.post(name: .hooksChanged, object: nil)
                monitor.invalidate()
            }
        }

        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit CMDC Island") { NSApp.terminate(nil) }
    }

    private func mark(_ status: CommandCodeStatus) -> String {
        switch status {
        case .working:   return "\u{25CF}"
        case .waiting:   return "\u{25CB}"
        case .completed: return "\u{2713}"
        case .idle:      return "\u{25CB}"
        case .unknown:   return "\u{003F}"
        }
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()

        // Defaults must land before anything reads a preference — the monitor's
        // first tick and the panel's geometry both depend on them.
        Pref.registerDefaults()

        // Accessory: no Dock icon, no app switcher entry, but the island and
        // the menu bar item both work.
        NSApp.setActivationPolicy(.accessory)

        CommandCodeMonitor.shared.start()

        let panel = NotchPanel(monitor: CommandCodeMonitor.shared)
        panel.orderFrontRegardless()
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.reposition()
        }

        NotificationCenter.default.addObserver(
            forName: .repositionPanel, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.reposition()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CommandCodeMonitor.shared.stop()
    }

    /// Only one island per Mac — old instances linger across rebuilds and
    /// would fight over the same pixel row.
    private func terminateIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.forEach { $0.terminate() }
    }
}
