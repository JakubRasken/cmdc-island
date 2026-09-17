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
    @discardableResult
    static func focus(session: CommandCodeSession) -> Bool {
        var pid = session.pid

        if pid == nil {
            pid = ProcessScan.pids(withWorkingDirectory: session.projectDir).first
        }

        guard let pid else { return false }

        if let tty = session.tty ?? ProcessScan.resolveTTY(from: pid) {
            if focus(tty: tty, pid: pid) { return true }
        }

        // Nothing scriptable matched; at minimum surface the right app.
        if let app = ProcessScan.owningApplication(pid: pid) {
            return activate(app)
        }
        return false
    }

    // MARK: - Per-terminal

    private static func focus(tty: String, pid: pid_t) -> Bool {
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

    private static func focusIterm(device: String) -> Bool {
        guard isRunning(bundleID: "com.googlecode.iterm2") else { return false }
        return Subprocess.osascript("""
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    // MARK: Terminal.app

    private static func focusTerminalApp(device: String) -> Bool {
        guard isRunning(bundleID: "com.apple.Terminal") else { return false }
        return Subprocess.osascript("""
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
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

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateAllWindows])
    }
}
