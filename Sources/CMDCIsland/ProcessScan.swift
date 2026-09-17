import AppKit
import Foundation

/// Reads the process table to answer two questions the transcript cannot:
/// which terminal a session belongs to, and whether it is still alive.
///
/// Every call here is a single short-lived `ps` (or `lsof`, on demand only).
/// Nothing runs on the polling path — the monitor relies on pid/tty handed to
/// it by the hook, and this is only consulted when a click needs resolving or
/// a hook-less session needs identifying.
enum ProcessScan {

    /// Walk up from `pid` until a process with a controlling terminal turns up.
    ///
    /// The hook has the same logic in JavaScript; this is the fallback for
    /// sessions whose hooks were not installed when they started.
    static func resolveTTY(from pid: pid_t) -> String? {
        guard let output = Subprocess.capture("/bin/ps", ["-axo", "pid=,ppid=,tty="]) else {
            return nil
        }

        var parentOf: [pid_t: pid_t] = [:]
        var ttyOf: [pid_t: String] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1])
            else { continue }
            parentOf[pid] = ppid
            ttyOf[pid] = String(parts[2])
        }

        var current = pid
        for _ in 0..<24 where current > 1 {
            if let tty = ttyOf[current], !tty.isEmpty, tty != "??", tty != "?" {
                return tty.replacingOccurrences(of: "/dev/", with: "")
            }
            guard let next = parentOf[current], next > 1 else { break }
            current = next
        }
        return nil
    }

    /// The GUI application that owns `pid`, found by walking the parent chain
    /// until a process that AppKit recognises as an app appears.
    ///
    /// This is what makes focusing work in terminals we have no scripting
    /// bridge for — VS Code, Warp, Alacritty, Ghostty — by at least bringing
    /// the right window forward.
    static func owningApplication(pid: pid_t) -> NSRunningApplication? {
        // A process can be its own app (rare for terminals, common for the
        // terminal's helper), so check the starting pid too.
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
            return app
        }

        guard let output = Subprocess.capture("/bin/ps", ["-axo", "pid=,ppid="]) else { return nil }

        var parentOf: [pid_t: pid_t] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            parentOf[pid] = ppid
        }

        var current = pid
        for _ in 0..<24 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bundle = app.bundleIdentifier,
               bundle != "com.apple.loginwindow" {
                return app
            }
            guard let next = parentOf[current], next > 1 else { break }
            current = next
        }
        return nil
    }

    /// Pids of `node` processes whose working directory is `directory`.
    ///
    /// `lsof` is the only portable way to ask for another process's cwd; it is
    /// not cheap, so this is called on click for hook-less sessions only.
    static func pids(withWorkingDirectory directory: String) -> [pid_t] {
        let target = canonical(directory)
        // `-c node` limits the walk to Command Code's own runtime, which keeps
        // this from enumerating every process on the machine.
        guard let output = Subprocess.capture(
            "/usr/sbin/lsof", ["-a", "-d", "cwd", "-c", "node", "-Fn"],
            timeout: 4
        ) else { return [] }

        var results: [pid_t] = []
        var currentPid: pid_t?

        for line in output.split(separator: "\n") {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPid = pid_t(value)
            case "n":
                guard let pid = currentPid, canonical(value) == target else { continue }
                if !results.contains(pid) { results.append(pid) }
            default:
                break
            }
        }
        return results
    }

    /// Trailing slashes and symlinks make path comparison lie; normalise both.
    private static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path
    }
}
