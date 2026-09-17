import Foundation

// MARK: - Status

/// What a Command Code session is doing, as far as we can *honestly* tell.
///
/// The four hook events are the only trustworthy live signal. `Stop` fires
/// when the assistant finishes a turn, so "the turn ended" is knowable; there
/// is no event for "the user is mid-prompt", which is why `.waiting` and
/// `.idle` are separated by recency rather than by a flag we do not have.
///
/// Nothing here guesses. A session we cannot classify is `.unknown`.
enum CommandCodeStatus: String, Sendable, CaseIterable {
    /// Inside a turn: tools are firing, the transcript is being appended to.
    case working
    /// A turn just ended and the session is fresh — Command Code wants you.
    case waiting
    /// The process is around but nothing has happened in a while.
    case idle
    /// Transient flash immediately after a turn ends, before it settles.
    case completed
    /// No usable signal.
    case unknown

    /// Ordering used to pick the single status that represents many sessions.
    /// Attention-worthy states win over quiet ones.
    var attentionRank: Int {
        switch self {
        case .waiting:   return 4
        case .working:   return 3
        case .completed: return 2
        case .idle:      return 1
        case .unknown:   return 0
        }
    }

    /// Short word for the collapsed pill. Deliberately terse — the pill is
    /// roughly 40pt of text wide.
    var compactLabel: String? {
        switch self {
        case .working:   return "Working"
        case .waiting:   return "Needs you"
        case .completed: return "Done"
        case .idle:      return nil
        case .unknown:   return nil
        }
    }

    var label: String {
        switch self {
        case .working:   return "Working"
        case .waiting:   return "Waiting for you"
        case .idle:      return "Idle"
        case .completed: return "Finished"
        case .unknown:   return "Unknown"
        }
    }
}

// MARK: - Session

/// One Command Code session.
///
/// Assembled from three local sources, deliberately kept separate so the
/// freshest wins per field:
///
///   * the transcript JSONL (`~/.commandcode/projects/<slug>/<id>.jsonl`)
///     for prompts, tool activity and turn boundaries,
///   * the sidecar `<id>.meta.json` for the session title,
///   * the hook spool for live status and the owning pid/tty.
///
/// Everything is local; nothing is ever sent anywhere.
struct CommandCodeSession: Identifiable, Equatable, Sendable {
    let id: String
    var projectDir: String
    var transcriptPath: String

    var title: String?
    var model: String?

    var status: CommandCodeStatus
    /// Human-readable "what is happening", e.g. `Editing auth.ts`.
    var activity: String?
    /// The most recent thing the user typed.
    var lastPrompt: String?
    /// Canonical tool id of the latest tool call, e.g. `edit_file`.
    var lastTool: String?
    /// Assistant's latest visible text, used when there is no better activity.
    var lastAssistantText: String?

    var startedAt: Date
    var lastActivityAt: Date

    /// Owning process, when a hook told us. Used to focus the terminal.
    var pid: Int32?
    var tty: String?
    var terminalApp: String?

    /// A process is believed to still be attached.
    var isLive: Bool

    // MARK: Derived

    /// Last path component of the project directory.
    var projectName: String {
        let trimmed = projectDir.hasSuffix("/")
            ? String(projectDir.dropLast())
            : projectDir
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    /// Home-relative project path (`~/Projects/my-app`).
    var displayPath: String {
        (projectDir as NSString).abbreviatingWithTildeInPath
    }

    /// Title if the user named the session, else the project folder name.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return projectName
    }

    /// The single line worth putting under the header.
    ///
    /// Preference order is "what is happening now" → "what you asked for" →
    /// "where it is", so the expanded island never shows an empty row.
    var subtitle: String {
        if let activity, !activity.isEmpty { return activity }
        if let lastPrompt, !lastPrompt.isEmpty { return lastPrompt }
        return displayPath
    }

    /// Short model name for the chip, e.g. `deepseek-v4.1-flash`.
    var shortModel: String? {
        guard let model, !model.isEmpty else { return nil }
        let parts = model.split(separator: "/")
        return parts.count > 1 ? String(parts.last!) : model
    }
}

// MARK: - Aggregate

/// The one-line summary the collapsed pill renders for N sessions.
struct CommandCodeSummary: Equatable, Sendable {
    var count: Int
    var status: CommandCodeStatus

    static let empty = CommandCodeSummary(count: 0, status: .idle)

    var isEmpty: Bool { count == 0 }

    /// Dot colour follows the loudest session.
    var compactLabel: String? {
        guard count > 1 else { return status.compactLabel }
        switch status {
        case .working:   return "\(count) working"
        case .waiting:   return "\(count) waiting"
        case .completed: return "\(count) done"
        default:         return nil
        }
    }
}
