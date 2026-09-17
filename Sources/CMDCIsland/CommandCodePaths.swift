import Foundation

/// Every filesystem location Command Code owns that the island touches.
///
/// All reads are local and read-only. The only path ever written to is
/// `eventsURL`, the hook spool, plus `settingsURL` when hooks are installed.
enum CommandCodePaths {

    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.commandcode`
    static var root: URL {
        home.appendingPathComponent(".commandcode", isDirectory: true)
    }

    /// `~/.commandcode/projects` — one directory per project, each holding
    /// `<session-id>.jsonl` transcripts and their sidecars.
    static var projectsURL: URL {
        root.appendingPathComponent("projects", isDirectory: true)
    }

    /// `~/.commandcode/cmdc-island` — our own scratch directory.
    static var islandURL: URL {
        root.appendingPathComponent("cmdc-island", isDirectory: true)
    }

    /// Append-only spool the installed hook writes to.
    static var eventsURL: URL {
        islandURL.appendingPathComponent("events.jsonl")
    }

    /// `~/.commandcode/settings.json` — user-scope hook configuration.
    static var settingsURL: URL {
        root.appendingPathComponent("settings.json")
    }

    /// Creates `~/.commandcode/cmdc-island` if needed.
    @discardableResult
    static func ensureIslandDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: islandURL, withIntermediateDirectories: true
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sidecars

    /// `<transcript>.jsonl` → `<id>.meta.json`
    static func metaURL(forTranscript path: String) -> URL {
        URL(fileURLWithPath: path)
            .deletingPathExtension()
            .appendingPathExtension("meta.json")
    }

    /// Sidecars that live next to a transcript but are not transcripts
    /// themselves. Checkpoint files in particular are large and irrelevant.
    static func isTranscriptFile(_ name: String) -> Bool {
        name.hasSuffix(".jsonl")
            && !name.hasSuffix(".checkpoints.jsonl")
            && !name.hasSuffix(".prompts.jsonl")
    }

    static func isCheckpointFile(_ name: String) -> Bool {
        name.hasSuffix(".checkpoints.jsonl")
    }
}
