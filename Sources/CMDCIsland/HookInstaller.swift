import Foundation

/// Installs and removes the Command Code hook that feeds the island.
///
/// This is the only place the app writes outside its own directory, so it is
/// deliberately conservative:
///
///   * the existing `settings.json` is **merged**, never replaced — unknown
///     keys survive untouched,
///   * an unparseable `settings.json` aborts the install instead of being
///     overwritten (a hand-edited file with a trailing comma must not be
///     destroyed by a menu bar app),
///   * a one-time backup is written before the first modification,
///   * installing twice is a no-op.
///
/// Hooks are opt-in. Without them the island still works — status is derived
/// from transcript writes — it is just less immediate.
enum HookInstaller {

    enum State: Equatable {
        case installed
        case notInstalled
        /// `settings.json` is not valid JSON; we refuse to touch it.
        case settingsUnreadable
        case failed(String)
    }

    /// Path the hook script is written to.
    static var scriptURL: URL {
        CommandCodePaths.islandURL.appendingPathComponent(HookScript.fileName)
    }

    /// The exact command string registered in `settings.json`.
    static var hookCommand: String? {
        guard let node = nodePath else { return nil }
        return "\"\(node)\" \"\(scriptURL.path)\""
    }

    // MARK: - Node discovery

    /// Command Code cannot run without Node 22+, so this normally succeeds.
    /// Homebrew's Apple Silicon prefix is checked first because that is where
    /// a `brew install node` lands.
    static var nodePath: String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "/opt/local/bin/node",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return Subprocess.which("node")
    }

    // MARK: - State

    static func currentState() -> State {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .notInstalled
        }
        guard let command = hookCommand else { return .notInstalled }

        switch readSettings() {
        case .failure:
            return .settingsUnreadable
        case .success(let settings):
            let commands = registeredCommands(in: settings)
            return commands.contains(command) ? .installed : .notInstalled
        }
    }

    // MARK: - Install

    @discardableResult
    static func install() -> State {
        guard let command = hookCommand else {
            return .failed(
                "Node.js was not found, so the hook cannot be installed. "
                + "This only happens if you use the Command Code Desktop app without the CLI — "
                + "the app embeds its own runtime and does not put `node` on your PATH. "
                + "The island still works; it just derives status from transcripts instead."
            )
        }

        let settingsResult = readSettings()
        let settings: [String: Any]
        switch settingsResult {
        case .success(let value):
            settings = value
        case .failure(let error):
            return .failed(error.message)
        }

        // 1. Write the script.
        do {
            CommandCodePaths.ensureIslandDirectory()
            try HookScript.source.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            return .failed("Could not write the hook script: \(error.localizedDescription)")
        }

        // 2. Clear any stale pid/tty cache so a fresh session resolves cleanly.
        try? FileManager.default.removeItem(
            at: CommandCodePaths.islandURL.appendingPathComponent("proc")
        )

        // 3. Merge the hook into settings.
        var merged = settings
        var hooks = merged["hooks"] as? [String: Any] ?? [:]
        let events = ["PreToolUse", "PostToolUse", "Stop", "SessionStart"]

        for event in events {
            var definitions = hooks[event] as? [[String: Any]] ?? []
            let alreadyPresent = definitions.contains { definition in
                (definition["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String) == command
                } ?? false
            }
            if !alreadyPresent {
                // No `matcher`: for tool events that means "every tool", and for
                // `Stop`/`SessionStart` a matcher would prevent the hook from
                // firing at all.
                definitions.append([
                    "hooks": [["type": "command", "command": command]],
                ])
            }
            hooks[event] = definitions
        }
        merged["hooks"] = hooks

        do {
            try backupOnce()
            try writeSettings(merged)
        } catch {
            return .failed("Could not update settings.json: \(error.localizedDescription)")
        }

        return currentState()
    }

    // MARK: - Uninstall

    @discardableResult
    static func uninstall() -> State {
        let result = readSettings()
        guard case .success(var settings) = result else {
            if case .failure(let error) = result { return .failed(error.message) }
            return .notInstalled
        }

        guard var hooks = settings["hooks"] as? [String: Any] else {
            try? removeScript()
            return .notInstalled
        }

        // Drop only entries that point at our own script. Matching on the
        // island directory rather than the bare file name means another tool's
        // `hook.mjs` is never touched.
        let ourDirectory = CommandCodePaths.islandURL.path

        for (event, value) in hooks {
            guard var definitions = value as? [[String: Any]] else { continue }

            definitions = definitions.compactMap { definition in
                guard var entries = definition["hooks"] as? [[String: Any]] else { return definition }
                entries.removeAll { entry in
                    (entry["command"] as? String)?.contains(ourDirectory) ?? false
                }
                if entries.isEmpty { return nil }          // definition now empty
                var updated = definition
                updated["hooks"] = entries
                return updated
            }

            if definitions.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = definitions
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        do {
            try writeSettings(settings)
            try removeScript()
        } catch {
            return .failed("Could not update settings.json: \(error.localizedDescription)")
        }

        return .notInstalled
    }

    private static func removeScript() throws {
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            try FileManager.default.removeItem(at: scriptURL)
        }
    }

    // MARK: - Spool

    /// Deletes the event spool. Used when the monitor wants a clean slate —
    /// for instance after the format version changes.
    static func clearSpool() {
        try? FileManager.default.removeItem(at: CommandCodePaths.eventsURL)
    }

    // MARK: - settings.json I/O

    /// Why a settings read failed, in words meant for the user.
    ///
    /// A dedicated type rather than a bare `String`: `Result` constrains its
    /// `Failure` to `Error`, and `String` does not conform to it. Extending
    /// `String` to conform would work but is a retroactive conformance of an
    /// imported type and would break under stricter language modes.
    private struct SettingsError: Error {
        var message: String
    }

    private static func readSettings() -> Result<[String: Any], SettingsError> {
        let url = CommandCodePaths.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .success([:]) }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .success([:])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(SettingsError(
                message: "\(url.path) is not valid JSON, so it was left untouched. Fix it, then try again."
            ))
        }
        return .success(object)
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        CommandCodePaths.ensureIslandDirectory()
        try data.write(to: CommandCodePaths.settingsURL, options: .atomic)
    }

    /// Keeps the user's original file around the first time we touch it.
    private static func backupOnce() throws {
        let url = CommandCodePaths.settingsURL
        let backup = CommandCodePaths.islandURL.appendingPathComponent("settings.json.backup")

        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path)
        else { return }

        let data = try Data(contentsOf: url)
        try data.write(to: backup, options: .atomic)
    }

    /// Every hook command currently registered anywhere in `settings.json`.
    private static func registeredCommands(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for (_, value) in hooks {
            guard let definitions = value as? [[String: Any]] else { continue }
            for definition in definitions {
                guard let entries = definition["hooks"] as? [[String: Any]] else { continue }
                for entry in entries {
                    if let command = entry["command"] as? String { commands.append(command) }
                }
            }
        }
        return commands
    }
}
