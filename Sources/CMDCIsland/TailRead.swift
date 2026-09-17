import Foundation

/// Decoding the trailing window of a Command Code transcript.
///
/// Transcripts are append-only JSONL and grow without bound — a long session
/// passes 1 MB quickly and can reach far more. Every read therefore seeks into
/// a byte window rather than slurping the file, and byte offsets chosen this
/// way regularly land in the middle of a multi-byte UTF-8 sequence: an emoji,
/// a curly quote, an accented path, a box-drawing character in tool output.
///
/// `String(data:encoding:.utf8)` is strict and returns nil for exactly that
/// input, which would blank a whole session card. Decoding lossily cannot
/// fail; the replacement characters only ever land in the window's first line,
/// which every caller discards as a partial record.
///
/// Adapted from Agents Island (MIT) — `TailRead.swift`.
enum TailRead {

    /// Decode a byte window that may begin mid-character.
    static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Usable lines from a tail window.
    ///
    /// - Parameter dropsFirstLine: whether the window began mid-line, making
    ///   its first line a fragment of a record that started before the offset.
    static func lines(_ data: Data, dropsFirstLine: Bool) -> [Substring] {
        var lines = decode(data).split(separator: "\n", omittingEmptySubsequences: true)
        if dropsFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Streaming form used once a session is known and we hold an explicit
    /// read offset: only *complete* lines are handed to `body`, and the
    /// returned byte count excludes any trailing partial line so the next pass
    /// re-reads from the start of that line.
    ///
    /// This is the property that makes tailing a file that is being written
    /// right now safe: a half-flushed JSON object is never parsed.
    ///
    /// - Returns: the number of bytes of complete lines consumed.
    @discardableResult
    static func consumeLines(
        handle: FileHandle,
        fromOffset: UInt64,
        chunkSize: Int = 1 * 1024 * 1024,
        _ body: (Substring) -> Void
    ) -> UInt64 {
        do {
            try handle.seek(toOffset: fromOffset)
        } catch {
            return 0
        }

        var carry = Data()          // bytes after the last newline seen so far
        var completeBytes: UInt64 = 0

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var buffer = carry
            buffer.append(chunk)

            guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
                carry = buffer      // still no complete line — keep accumulating
                continue
            }

            // Whole lines only, so a multi-byte character can never be split
            // across the boundary and decoding is exact.
            for line in decode(buffer[...lastNewline])
                .split(separator: "\n", omittingEmptySubsequences: true) {
                body(line)
            }
            completeBytes += UInt64(buffer.distance(from: buffer.startIndex, to: buffer.index(after: lastNewline)))
            carry = Data(buffer[buffer.index(after: lastNewline)...])
        }

        return completeBytes
    }
}
