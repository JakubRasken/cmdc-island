import Foundation

/// A single line from the hook spool.
///
/// The installed hook (`HookScript`) runs on every `PreToolUse`, `PostToolUse`,
/// `Stop` and `SessionStart`, reads Command Code's stdin payload, and appends
/// one compact JSON object here. That gives the island a real-time signal
/// without ever shelling out to Command Code or scraping a terminal.
///
/// Parsing is deliberately forgiving: an unknown `event` is dropped, a missing
/// field stays nil, and a malformed line is ignored. Command Code is free to
/// add fields or events without breaking us.
struct CommandCodeHookEvent: Equatable, Sendable {

    enum Kind: String, Sendable {
        case preToolUse   = "PreToolUse"
        case postToolUse  = "PostToolUse"
        case stop         = "Stop"
        case sessionStart = "SessionStart"

        /// Events we do not recognise are ignored rather than guessed at.
        init?(wire: String) {
            self.init(rawValue: wire)
        }
    }

    var kind: Kind
    var sessionID: String
    var cwd: String
    var transcriptPath: String?

    var toolName: String?
    var toolDisplayName: String?
    /// Pre-rendered short description, e.g. `npm run build`.
    var detail: String?

    var permissionMode: String?
    var pid: Int32?
    var tty: String?
    /// `SessionStart` only: `startup` | `resume` | `clear`.
    var source: String?

    var at: Date
    /// Monotonic sequence stamped by the hook, used to discard out-of-order
    /// appends when several hooks fire in parallel (PostToolUse and Stop do).
    var seq: UInt64?

    // MARK: - Parsing

    /// Parse one spool line. Returns nil for anything unusable.
    static func parse(line: Substring, decoder: JSONDecoder = .hookSpool) -> CommandCodeHookEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let raw = try? decoder.decode(RawEvent.self, from: data) else { return nil }
        return raw.event
    }

    /// Wire format. Kept private so the tolerant decoding rules live in one
    /// place and the public struct stays clean.
    private struct RawEvent: Decodable {
        var event: CommandCodeHookEvent?

        enum CodingKeys: String, CodingKey {
            case v, event, sessionId, cwd, transcript, tool, display,
                 detail, mode, pid, tty, source, at, seq
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            guard let name = try c.decodeIfPresent(String.self, forKey: .event),
                  let kind = Kind(wire: name),
                  let sessionID = try c.decodeIfPresent(String.self, forKey: .sessionId),
                  !sessionID.isEmpty
            else {
                // Unknown event or no session identity — nothing to attribute.
                return
            }

            // Hooks stamp epoch seconds as a double. A missing or absurd value
            // falls back to "now" rather than poisoning the recency ordering.
            let stamp = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
            let date = stamp > 0 ? Date(timeIntervalSince1970: stamp) : Date()

            self.event = CommandCodeHookEvent(
                kind: kind,
                sessionID: sessionID,
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                transcriptPath: try c.decodeIfPresent(String.self, forKey: .transcript),
                toolName: try c.decodeIfPresent(String.self, forKey: .tool),
                toolDisplayName: try c.decodeIfPresent(String.self, forKey: .display),
                detail: try c.decodeIfPresent(String.self, forKey: .detail),
                permissionMode: try c.decodeIfPresent(String.self, forKey: .mode),
                pid: try c.decodeIfPresent(Int32.self, forKey: .pid),
                tty: try c.decodeIfPresent(String.self, forKey: .tty),
                source: try c.decodeIfPresent(String.self, forKey: .source),
                at: date,
                seq: try c.decodeIfPresent(UInt64.self, forKey: .seq)
            )
        }
    }
}

extension JSONDecoder {
    /// Decoder specialised for the hook spool: tolerant of extra keys and of
    /// keys whose value arrived with an unexpected type (the hook is a shell
    /// script and `pid`/`tty` can come back as strings on some systems).
    static var hookSpool: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
