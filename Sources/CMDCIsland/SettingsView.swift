import AppKit
import SwiftUI

/// Settings. Deliberately short: everything here changes what the island shows
/// or how fast it reacts, and nothing here configures an agent, a provider, or
/// a quota, because none of those exist in this app.
struct SettingsView: View {

    @ObservedObject var monitor: CommandCodeMonitor

    @AppStorage(Pref.Key.showModel) private var showModel = true
    @AppStorage(Pref.Key.expandOnHover) private var expandOnHover = true
    @AppStorage(Pref.Key.expandOnFinished) private var expandOnFinished = true
    @AppStorage(Pref.Key.singleSessionOnly) private var singleSessionOnly = false

    @AppStorage(Pref.Key.activeWindowMinutes) private var activeWindowMinutes = 20.0
    @AppStorage(Pref.Key.completedFlashSeconds) private var completedFlashSeconds = 8.0
    @AppStorage(Pref.Key.idleAfterSeconds) private var idleAfterSeconds = 300.0

    @AppStorage(Pref.Key.hideInFullscreen) private var hideInFullscreen = false
    @AppStorage(Pref.Key.notchWidthOffset) private var notchWidthOffset = 0.0
    @AppStorage(Pref.Key.notchHeightOffset) private var notchHeightOffset = 0.0
    @AppStorage(Pref.Key.displaySelection) private var displaySelection = "auto"

    @State private var hookState: HookInstaller.State = .notInstalled
    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var hookError: String?

    var body: some View {
        Form {
            hooksSection
            behaviourSection
            timingSection
            displaySection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 600)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .hooksChanged)) { _ in refresh() }
    }

    // MARK: - Hooks

    private var hooksSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hookIcon)
                    .foregroundStyle(hookTint)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hookTitle).font(.system(size: 12, weight: .semibold))
                    Text(hookDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                switch hookState {
                case .installed:
                    Button("Remove") { uninstall() }
                case .notInstalled, .failed, .settingsUnreadable:
                    Button("Install") { install() }
                        .disabled(hookState == .settingsUnreadable)
                }
            }

            if let hookError {
                Text(hookError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Command Code hooks")
        } footer: {
            Text("The hook is a small Node script written to ~/.commandcode/cmdc-island/hook.mjs and registered in ~/.commandcode/settings.json. It reports tool activity, turn ends and terminal identity. Nothing leaves your machine.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var hookTitle: String {
        switch hookState {
        case .installed:         return "Installed"
        case .notInstalled:      return "Not installed"
        case .settingsUnreadable: return "settings.json is unreadable"
        case .failed:            return "Install failed"
        }
    }

    private var hookDetail: String {
        switch hookState {
        case .installed:
            return "Status updates arrive the moment a tool runs or a turn ends."
        case .notInstalled:
            return "Without hooks the island still works, but status lags — it can only tell a turn ended once the transcript stops growing."
        case .settingsUnreadable:
            return "Your Command Code settings.json is not valid JSON, so it was left untouched. Fix it, then install."
        case .failed(let message):
            return message
        }
    }

    private var hookIcon: String {
        switch hookState {
        case .installed:  return "checkmark.circle.fill"
        case .failed, .settingsUnreadable: return "exclamationmark.triangle.fill"
        case .notInstalled: return "circle.dashed"
        }
    }

    private var hookTint: Color {
        switch hookState {
        case .installed: return .green
        case .failed, .settingsUnreadable: return .orange
        case .notInstalled: return .secondary
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        Section("Island") {
            Toggle("Expand on hover", isOn: $expandOnHover)
            Toggle("Expand when a session finishes", isOn: $expandOnFinished)
            Toggle("Show model name", isOn: $showModel)
            Toggle("Only show the active session", isOn: $singleSessionOnly)
        }
    }

    // MARK: - Timing

    private var timingSection: some View {
        Section {
            Stepper(value: $activeWindowMinutes, in: 2...180, step: 1) {
                LabeledContent("Keep sessions for") {
                    Text("\(Int(activeWindowMinutes)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $completedFlashSeconds, in: 2...60, step: 1) {
                LabeledContent("Show \u{201C}Finished\u{201D} for") {
                    Text("\(Int(completedFlashSeconds)) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $idleAfterSeconds, in: 30...3600, step: 30) {
                LabeledContent("Go idle after") {
                    Text(idleLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("Nothing older than the retention window is ever read. Sessions drop off the island once they have been quiet that long.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var idleLabel: String {
        let seconds = Int(idleAfterSeconds)
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Show on", selection: $displaySelection) {
                Text("Automatic").tag("auto")
                ForEach(displays, id: \.id) { display in
                    Text(display.name).tag("id:\(display.id)")
                }
            }
            .onChange(of: displaySelection) { _, _ in reposition() }

            Toggle("Hide in fullscreen apps", isOn: $hideInFullscreen)
                .onChange(of: hideInFullscreen) { _, _ in reposition() }

            Stepper(value: $notchWidthOffset, in: -60...120, step: 2) {
                LabeledContent("Notch width") {
                    Text("\(Int(notchWidthOffset)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .onChange(of: notchWidthOffset) { _, _ in reposition() }

            Stepper(value: $notchHeightOffset, in: -10...40, step: 1) {
                LabeledContent("Notch height") {
                    Text("\(Int(notchHeightOffset)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .onChange(of: notchHeightOffset) { _, _ in reposition() }

            Toggle("Launch at login", isOn: $loginItemEnabled)
                .onChange(of: loginItemEnabled) { _, value in
                    loginItemEnabled = LoginItem.setEnabled(value)
                }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Sessions", value: "\(monitor.sessions.count) tracked")
            LabeledContent("Transcripts", value: CommandCodePaths.projectsURL.path)
                .help(CommandCodePaths.projectsURL.path)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([CommandCodePaths.projectsURL])
                }
                Button("Refresh now") { monitor.invalidate() }
                Spacer()
                Button("Clear event spool") { HookInstaller.clearSpool() }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        hookState = HookInstaller.currentState()
        loginItemEnabled = LoginItem.isEnabled
    }

    private func install() {
        let state = HookInstaller.install()
        hookState = state
        if case .failed(let message) = state { hookError = message } else { hookError = nil }
        CommandCodeMonitor.shared.invalidate()
    }

    private func uninstall() {
        let state = HookInstaller.uninstall()
        hookState = state
        hookError = nil
        CommandCodeMonitor.shared.invalidate()
    }

    private func reposition() {
        NotificationCenter.default.post(name: .repositionPanel, object: nil)
    }

    // MARK: - Displays

    private struct DisplayOption {
        let id: CGDirectDisplayID
        let name: String
    }

    private var displays: [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let name = screen.localizedName
            return DisplayOption(id: id, name: screen.safeAreaInsets.top > 0 ? "\(name) (notch)" : name)
        }
    }
}
