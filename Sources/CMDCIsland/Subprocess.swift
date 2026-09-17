import Foundation

/// Minimal process plumbing. Everything here is a short-lived, bounded call —
/// `ps`, `osascript`, `open` — never a long-running child.
enum Subprocess {

    /// Run an executable and capture stdout. Returns nil on spawn failure.
    static func capture(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 3
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a large enough output would otherwise fill the
        // pipe buffer and deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }

    /// Run and ignore the result. Used for fire-and-forget `open`/`activate`.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    static func osascript(_ source: String) -> Bool {
        run("/usr/bin/osascript", ["-e", source])
    }

    /// First match of `name` on the user's PATH, via `/usr/bin/env which`.
    static func which(_ name: String) -> String? {
        guard let output = capture("/usr/bin/env", ["which", name]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
