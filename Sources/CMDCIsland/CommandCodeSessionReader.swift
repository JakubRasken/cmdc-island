import Foundation

/// Everything the island knows about one transcript, accumulated incrementally.
///
/// The reader never re-parses a whole file: it holds a byte offset and folds
/// each new complete line into this struct. A cold start reads only the tail,
/// so a 100 MB session costs the same as a 100 KB one.
struct TranscriptState: Equatable, Sendable {
    /// Bytes of complete lines consumed so far.
    var offset: UInt64 = 0
    /// No lines have been read yet — the next pass must drop a partial head.
    var needsColdStart = true
    var isFirstConsume = true

    var id: String?
    var cwd: String?
    var startedAt: Date?
    var model: String?

    var lastPrompt: String?
    var activity: String?
    var lastTool: String?
    var lastAssistantText: String?

    var lastEntryAt: Date?
    /// When the assistant last finished a turn (`text` with no `tool_use`).
    var lastTurnEndedAt: Date?
    /// A turn is in flight: a prompt was sent, tools are running, or the model
    /// is mid-response.
    var isMidTurn = false

    /// Lines that failed to parse. Surfaced in Settings, never fatal — a torn
    /// or half-written transcript must not take the island down.
    var malformedLines = 0
}

/// Reads Command Code transcripts (`~/.commandcode/projects/<slug>/<id>.jsonl`).
///
/// Schema, verified against real transcripts:
///
///   * `{"type":"session","id":…,"timestamp":…,"cwd":…}` — header, line 1
///   * `{"type":"message","timestamp":…,"message":{"role":"user"|"assistant",
///      "content":[…]}, "model":…}` where content blocks are one of
///      `text`, `thinking`, `tool_use`, `tool_result`
///   * `{"type":"compaction",…}` — history summarised, conversation continues
///
/// Unknown entry types and unknown block types are skipped, so a future
/// Command Code version adding records degrades gracefully instead of breaking.
enum CommandCodeSessionReader {

    /// How much of an unseen transcript to read. Enough for the last few turns
    /// — which is all the card shows — without touching the rest of the file.
    static let coldTailBytes: UInt64 = 256 * 1024

    // MARK: - Header

    /// Cheap read of only the first line, to learn the session's working
    /// directory without parsing the body. Used during discovery.
    static func readHeader(path: String) -> (id: String?, cwd: String?, startedAt: Date?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 8192), !head.isEmpty,
              let newline = head.firstIndex(of: UInt8(ascii: "\n"))
        else { return (nil, nil, nil) }

        let line = TailRead.decode(Data(head[..<newline]))
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session"
        else { return (nil, nil, nil) }

        return (
            obj["id"] as? String,
            obj["cwd"] as? String,
            parseDate(obj["timestamp"] as? String)
        )
    }

    // MARK: - Incremental consume

    /// Fold any newly-appended complete lines into `state`.
    ///
    /// - Parameter size: current file size, used only to decide the cold-start
    ///   window. A file whose size shrank (rewind rewrote it) resets state.
    static func consume(path: String, size: UInt64, state: inout TranscriptState) {
        guard size > 0 else { return }

        // File replaced or truncated — start over rather than reading garbage.
        if state.offset > size {
            state = TranscriptState()
        }

        let start: UInt64
        if state.needsColdStart {
            start = size > coldTailBytes ? size - coldTailBytes : 0
        } else {
            start = state.offset
            guard start < size else { return }   // nothing new
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        // A cold read that begins mid-file begins mid-line; that fragment is
        // discarded here rather than in TailRead, which has no way to know.
        var skipFirst = state.needsColdStart && start > 0

        let consumed = TailRead.consumeLines(handle: handle, fromOffset: start) { line in
            if skipFirst {
                skipFirst = false
                return
            }
            consume(line: line, into: &state)
        }

        state.offset = start + consumed
        state.needsColdStart = false
        if state.isFirstConsume { state.isFirstConsume = false }
    }

    // MARK: - Line parsing

    private static func consume(line: Substring, into state: inout TranscriptState) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            state.malformedLines += 1
            return
        }

        switch type {
        case "session":
            state.id = object["id"] as? String ?? state.id
            state.cwd = object["cwd"] as? String ?? state.cwd
            state.startedAt = parseDate(object["timestamp"] as? String) ?? state.startedAt

        case "message":
            guard let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String
            else {
                state.malformedLines += 1
                return
            }
            let at = parseDate(object["timestamp"] as? String)
            if let model = object["model"] as? String, !model.isEmpty {
                state.model = model
            }
            consumeMessage(role: role, message: message, at: at, into: &state)

        case "compaction":
            // History was summarised; the conversation continues, so this is
            // activity but never a turn boundary.
            if let at = parseDate(object["timestamp"] as? String) {
                state.lastEntryAt = at
            }

        default:
            break
        }
    }

    private static func consumeMessage(
        role: String,
        message: [String: Any],
        at: Date?,
        into state: inout TranscriptState
    ) {
        if let at { state.lastEntryAt = at }

        let blocks = message["content"] as? [[String: Any]] ?? []

        switch role {
        case "user":
            // A user entry carrying tool results is the engine feeding results
            // back — the turn is still running, not a new prompt.
            var hasResult = false
            var userText = ""

            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    hasResult = true
                case "text":
                    if let text = block["text"] as? String { userText += text }
                default:
                    break
                }
            }

            if hasResult {
                state.isMidTurn = true
            } else if !userText.isEmpty {
                state.lastPrompt = display(userText, max: 240)
                state.activity = nil
                state.isMidTurn = true
                state.lastTurnEndedAt = nil
            }

        case "assistant":
            var toolName: String?
            var toolInput: [String: Any]?
            var assistantText = ""
            var hasThinking = false

            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { assistantText += text }
                case "thinking":
                    hasThinking = true
                case "tool_use":
                    // The last tool call in the batch is the most recent intent.
                    toolName = block["name"] as? String
                    toolInput = block["input"] as? [String: Any]
                default:
                    break
                }
            }

            if !assistantText.isEmpty {
                state.lastAssistantText = display(assistantText, max: 240)
            }

            if let toolName {
                state.lastTool = toolName
                state.activity = ToolActivity.describe(tool: toolName, input: toolInput)
                state.isMidTurn = true
                state.lastTurnEndedAt = nil
            } else if !assistantText.isEmpty || hasThinking {
                // Final response with no pending tool call — the turn is over.
                state.isMidTurn = false
                state.activity = nil
                state.lastTurnEndedAt = at ?? Date()
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    /// Collapse whitespace and clip to a single readable line. Prompts and
    /// replies routinely contain newlines and code fences; the island shows
    /// one line and never a wall of text.
    static func display(_ text: String, max: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > max
            ? String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
            : collapsed
    }
}

/// Turns a canonical tool id plus its arguments into one short phrase.
///
/// The island shows at most one line of "what is happening", so this is the
/// single place that decides how a tool call reads in English. Both input
/// paths funnel through it: the transcript reader passes the full `tool_use`
/// input, and the hook passes the single raw value it already extracted.
enum ToolActivity {

    /// From a transcript `tool_use` block.
    static func describe(tool: String, input: [String: Any]?) -> String? {
        phrase(tool: tool, detail: value(tool: tool, input: input))
    }

    /// From a hook event, where `detail` is already the raw argument.
    static func phrase(tool: String, detail: String?) -> String? {
        switch tool {
        case "shell_command":
            return detail.map { "Running " + shorten($0, max: 64) } ?? "Running a command"

        case "read_file":
            return detail.map { "Reading " + base($0) } ?? "Reading a file"

        case "write_file":
            return detail.map { "Writing " + base($0) } ?? "Writing a file"

        case "edit_file":
            return detail.map { "Editing " + base($0) } ?? "Editing a file"

        case "read_directory":
            return detail.map { "Listing " + base($0) } ?? "Listing a directory"

        case "glob":
            return detail.map { "Finding " + shorten($0, max: 48) } ?? "Finding files"

        case "grep":
            return detail.map { "Searching " + shorten($0, max: 48) } ?? "Searching the code"

        case "todo_write":
            return "Updating the plan"

        case "task":
            return detail.map { "Delegating " + shorten($0, max: 48) } ?? "Delegating"

        case "web_fetch", "web_search":
            return "Searching the web"

        case "read_plan", "write_plan":
            return "Working on the plan"

        default:
            // Unknown (or newly added) tool: read its name as a phrase rather
            // than inventing behaviour we cannot see.
            return prettify(tool)
        }
    }

    // MARK: - Argument extraction

    /// The one argument worth naming, per tool.
    private static func value(tool: String, input: [String: Any]?) -> String? {
        switch tool {
        case "shell_command":
            return string(input, "command")
        case "read_file", "write_file", "edit_file":
            return filePath(input)
        case "read_directory":
            return string(input, "path")
        case "glob", "grep":
            return string(input, "pattern")
        case "task":
            return string(input, "description")
        default:
            return nil
        }
    }

    private static func string(_ input: [String: Any]?, _ key: String) -> String? {
        guard let value = input?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Tools disagree on the key for the target file (`path` vs `file_path`
    /// vs `absolute_path`), so accept any of them.
    private static func filePath(_ input: [String: Any]?) -> String? {
        for key in ["file_path", "absolute_path", "path"] {
            if let value = string(input, key) { return value }
        }
        return nil
    }

    // MARK: - Formatting

    private static func base(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func shorten(_ text: String, max: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > max ? String(collapsed.prefix(max)) + "…" : collapsed
    }

    /// `read_directory` → `Read directory`
    private static func prettify(_ tool: String) -> String {
        let words = tool.split(separator: "_")
        guard let first = words.first else { return tool }
        let rest = words.dropFirst().joined(separator: " ")
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return rest.isEmpty ? head : "\(head) \(rest)"
    }
}
