import AppKit
import Foundation

/// Brings the terminal that owns a session to the front, at the exact tab or
/// pane where possible.
///
/// Precision depends on what the terminal exposes:
///
///   * **tmux** — `select-pane`, exact.
///   * **iTerm2 / Terminal** — AppleScript matched on the session's tty, exact.
///   * **WezTerm** — `wezterm cli activate-pane`, exact.
///   * **kitty** — `kitten @ focus-window` matched on the foreground pid.
///   * **anything else** (VS Code, Warp, Ghostty, Alacritty, …) — activate the
///     owning application. Approximate, but it puts you in the right window.
///
/// The tty is the key that unlocks all of this, and the tty normally arrives
/// from the hook. Sessions started before hooks were installed fall back to
/// resolving it from the process table on demand.
enum TerminalFocus {

    /// Returns true when something was actually brought forward.
    ///
    /// The tty is the key that unlocks exact focusing, and it normally arrives
    /// from the hook. Sessions started before hooks were installed fall back to
    /// resolving it from the process table on demand.
    @discardableResult
    static func focus(session: CommandCodeSession) -> Bool {
        if let pid = session.pid ?? ProcessScan.pids(withWorkingDirectory: session.projectDir).first {
            if let tty = session.tty ?? ProcessScan.resolveTTY(from: pid),
               focusTerminal(tty: tty, pid: pid) {
                return true
            }
            // Nothing scriptable matched; at minimum surface the right app.
            if let app = ProcessScan.owningApplication(pid: pid), activate(app) {
                return true
            }
        }

        // No process to attach to. Two cases land here: a headless (`cmd -p`)
        // run, or a session driven by the Desktop app, which embeds the agent
        // runtime and has no controlling terminal at all. Bringing the app
        // forward is the honest best effort — we cannot address a specific chat.
        return activateDesktopApp()
    }

    /// Brings the Command Code Desktop app forward, if it is running.
    ///
    /// Matched on bundle identity rather than a hard-coded id: the app installs
    /// to `/Applications/Command Code.app`, and the exact identifier is not
    /// documented, so name and path are both accepted.
    private static func activateDesktopApp() -> Bool {
        let wanted: Set<String> = ["command code", "commandcode", "command-code"]

        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleURL?.lastPathComponent ?? "")
                .replacingOccurrences(of: ".app", with: "")
                .lowercased()
            let identifier = (app.bundleIdentifier ?? "").lowercased()

            // Our own bundle id is `ai.cmdc-island`, so this cannot self-match.
            let looksLikeCommandCode = wanted.contains(name)
                || wanted.contains(bundle)
                || identifier.contains("commandcode")
                || identifier.contains("command-code")

            guard looksLikeCommandCode else { continue }
            return activate(app)
        }
        return false
    }

    // MARK: - Per-terminal

    /// Try every terminal we know how to drive, in order of precision.
    private static func focusTerminal(tty: String, pid: pid_t) -> Bool {
        let device = "/dev/\(tty)"

        if focusTmux(device: device) { return true }
        if focusIterm(device: device) { return true }
        if focusTerminalApp(device: device) { return true }
        if focusWezTerm(device: device) { return true }
        if focusKitty(pid: pid) { return true }

        return false
    }

    // MARK: tmux

    private static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// tmux pane id whose pty matches, e.g. `%3` for `/dev/ttys003`.
    private static func tmuxPane(device: String) -> String? {
        guard let tmux = tmuxPath,
              let output = Subprocess.capture(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        else { return nil }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0] == Substring(device) { return String(parts[1]) }
        }
        return nil
    }

    private static func focusTmux(device: String) -> Bool {
        guard let tmux = tmuxPath, let pane = tmuxPane(device: device) else { return false }
        // Selecting the window and pane makes it active for whichever client
        // is attached; we cannot identify the client reliably from here.
        Subprocess.run(tmux, ["select-window", "-t", pane])
        Subprocess.run(tmux, ["select-pane", "-t", pane])
        return true
    }

    // MARK: iTerm2

    /// The AppleScript reports `ok` only when it actually selected a session.
    ///
    /// Checking the exit status is not enough: `osascript` exits 0 after a
    /// loop that matched nothing, so a running iTerm would swallow the click
    /// and the WezTerm/kitty/activate fallbacks would never run.
    private static func focusIterm(device: String) -> Bool {
        guard isRunning(bundleID: "com.googlecode.iterm2") else { return false }
        return osascriptResult("""
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            select w
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """) == "ok"
    }

    // MARK: Terminal.app

    private static func focusTerminalApp(device: String) -> Bool {
        guard isRunning(bundleID: "com.apple.Terminal") else { return false }
        return osascriptResult("""
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected tab of w to t
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "miss"
        """) == "ok"
    }

    // MARK: WezTerm

    private static var weztermPath: String? {
        ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
         "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func focusWezTerm(device: String) -> Bool {
        guard let wezterm = weztermPath,
              let output = Subprocess.capture(wezterm, ["cli", "list", "--format", "json"]),
              let data = output.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        for pane in panes where pane["tty_name"] as? String == device {
            guard let id = pane["pane_id"] as? Int else { continue }
            Subprocess.run(wezterm, ["cli", "activate-pane", "--pane-id", String(id)])
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.github.wez.wezterm"
            ).first {
                _ = activate(app)
            }
            return true
        }
        return false
    }

    // MARK: kitty

    private static var kittenPath: String? {
        ["/opt/homebrew/bin/kitten", "/usr/local/bin/kitten",
         "/Applications/kitty.app/Contents/MacOS/kitten"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func focusKitty(pid: pid_t) -> Bool {
        guard let kitten = kittenPath,
              let output = Subprocess.capture(kitten, ["@", "ls"]),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        for osWindow in osWindows {
            for tab in (osWindow["tabs"] as? [[String: Any]] ?? []) {
                for window in (tab["windows"] as? [[String: Any]] ?? []) {
                    let foreground = window["foreground_processes"] as? [[String: Any]] ?? []
                    let matches = foreground.contains { entry in
                        guard let value = entry["pid"] as? Int else { return false }
                        // The session's own process, or anything in its tree.
                        return pid_t(value) == pid
                    }
                    guard matches, let id = window["id"] as? Int else { continue }
                    Subprocess.run(kitten, ["@", "focus-window", "--match", "id:\(id)"])
                    if let app = NSRunningApplication.runningApplications(
                        withBundleIdentifier: "net.kovidgoyal.kitty"
                    ).first {
                        _ = activate(app)
                    }
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Run AppleScript and return its trimmed result, so a script can report
    /// whether it actually matched rather than only that it did not error.
    private static func osascriptResult(_ source: String) -> String {
        guard let output = Subprocess.capture("/usr/bin/osascript", ["-e", source]) else {
            return ""
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateAllWindows])
    }
}
