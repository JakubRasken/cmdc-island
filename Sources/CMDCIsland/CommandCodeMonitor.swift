import Foundation
import Combine

/// The single source of truth the island renders.
///
/// Two local inputs are reconciled into one state per session:
///
///   * **transcripts** — `~/.commandcode/projects/<slug>/<id>.jsonl`, tailed
///     incrementally, which is authoritative for *content* (prompt, activity,
///     model) and for turn boundaries on a best-effort basis;
///   * **hook events** — appended by `HookScript` to `events.jsonl`, which are
///     authoritative for *live status*, because `Stop` firing is a fact and
///     "the transcript stopped growing" is only an inference.
///
/// Whichever source has the newer evidence wins, per session. This is what
/// makes the island degrade gracefully: with hooks installed it is immediate;
/// without them it still tracks turns, just a beat behind.
///
/// All parsing happens on a private serial queue; only the finished snapshot
/// crosses to the main thread, so a large transcript can never hitch the UI.
final class CommandCodeMonitor: ObservableObject {

    static let shared = CommandCodeMonitor()

    /// Sessions worth showing, most attention-worthy first.
    @Published private(set) var sessions: [CommandCodeSession] = []
    /// The one-line aggregate the collapsed pill renders.
    @Published private(set) var summary: CommandCodeSummary = .empty
    @Published private(set) var hooksInstalled = false

    /// A transient reason for the island to open on its own.
    @Published private(set) var spotlight: Spotlight?

    enum SpotlightKind: Equatable {
        case finished
    }

    struct Spotlight: Equatable {
        var kind: SpotlightKind
        var sessionID: String
        var at: Date
    }

    // MARK: - Private state (private queue only)

    private let queue = DispatchQueue(label: "ai.cmdc-island.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var records: [String: SessionRecord] = [:]
    private var spoolOffset: UInt64 = 0
    private var spoolPrimed = false
    private var lastPublishedStatus: [String: CommandCodeStatus] = [:]
    private var spotlightClearWork: DispatchWorkItem?
    private var hookStateCache: (installed: Bool, at: Date) = (false, .distantPast)

    /// Set by each scan; drives the polling interval.
    private var anyWorking = false
    private var currentInterval: TimeInterval = 1.0

    /// How often to look.
    ///
    /// The stat calls are ~1 ms, so CPU is not the cost — *wakeups* are. A
    /// timer that fires every 1.2 s keeps a laptop out of deep idle for 50
    /// wakeups a minute, and most of those find nothing. Fast only while
    /// something is genuinely running; 3 s otherwise, which is imperceptible
    /// for a thing you glance at.
    private static let activeInterval: TimeInterval = 1.0
    private static let idleInterval: TimeInterval = 3.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.rescan()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Reads `self.timer` rather than capturing the local, so the source
        // does not retain its own handler.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.rescan()
            self.retime()
        }
        timer.schedule(
            deadline: .now() + .seconds(2),
            repeating: .milliseconds(Int(Self.activeInterval * 1000)),
            leeway: .milliseconds(Int(Self.activeInterval * 400))
        )
        timer.resume()
        self.timer = timer
    }

    /// Reschedule only when the desired interval actually changed, so a steady
    /// state never re-arms.
    ///
    /// The leeway is deliberate: it lets the kernel coalesce this wakeup with
    /// others already scheduled, which is the difference between a timer that
    /// costs battery and one that does not.
    private func retime() {
        guard let timer else { return }

        let wanted = anyWorking ? Self.activeInterval : Self.idleInterval
        guard wanted != currentInterval else { return }
        currentInterval = wanted

        timer.schedule(
            deadline: .now() + wanted,
            repeating: .milliseconds(Int(wanted * 1000)),
            leeway: .milliseconds(Int(wanted * 400))
        )
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force a full re-read on the next tick — used after the user installs
    /// hooks, or clicks "Refresh".
    func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.records.removeAll()
            self.spoolOffset = 0
            self.spoolPrimed = false
            self.hookStateCache = (false, .distantPast)
            self.rescan()
        }
    }

    /// The session the island should focus when clicked: the loudest one.
    var primarySession: CommandCodeSession? {
        sessions.max { lhs, rhs in
            if lhs.status.attentionRank != rhs.status.attentionRank {
                return lhs.status.attentionRank < rhs.status.attentionRank
            }
            return lhs.lastActivityAt < rhs.lastActivityAt
        }
    }

    // MARK: - Scan

    private func rescan() {
        let now = Date()
        let activeWindow = TimeInterval(Pref.activeWindowMinutes * 60)

        // 1. Live status arrives first, so transcript reads can be attributed
        //    to a session that a hook already told us about.
        consumeSpool(now: now)

        // 2. Discover + tail transcripts.
        discover(now: now, activeWindow: activeWindow)

        // 3. Prune anything that has aged out, so memory stays flat.
        records = records.filter { now.timeIntervalSince($0.value.lastEvidenceAt) < activeWindow * 3 }

        // 4. Project to display models.
        let built = records.values
            .map { $0.session(now: now) }
            .filter { now.timeIntervalSince($0.lastActivityAt) < activeWindow }
            .sorted { lhs, rhs in
                if lhs.status.attentionRank != rhs.status.attentionRank {
                    return lhs.status.attentionRank > rhs.status.attentionRank
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }

        let installed = cachedHookState(now: now)
        let newSummary = Self.summarize(built)
        let spot = detectSpotlight(in: built, now: now)

        anyWorking = built.contains { $0.status == .working }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if self.sessions != built { self.sessions = built }
            if self.summary != newSummary { self.summary = newSummary }
            if self.hooksInstalled != installed { self.hooksInstalled = installed }

            if let spot {
                self.spotlight = spot
                self.scheduleSpotlightClear(id: spot.sessionID, at: spot.at)
            }
        }
    }

    // MARK: - Spool

    private func consumeSpool(now: Date) {
        let url = CommandCodePaths.eventsURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        guard size > 0 else { return }

        // A new spool (or a rotated one) means our offset is meaningless.
        if size < spoolOffset {
            spoolOffset = 0
            spoolPrimed = false
        }

        // Rotate rather than grow forever. Only when fully consumed, so no
        // event is ever dropped.
        if size > 4 * 1024 * 1024, spoolOffset >= size {
            try? FileManager.default.removeItem(at: url)
            spoolOffset = 0
            spoolPrimed = false
            return
        }

        guard spoolOffset < size else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }

        // On the first read of the session, replay only the tail of the spool.
        // Replaying is deliberate: the most recent event for a live session is
        // usually a `PreToolUse`, which is exactly the status we want on
        // launch. Stale ones age out through the normal recency rules.
        let coldStart = !spoolPrimed
        spoolPrimed = true

        let start: UInt64 = (coldStart && size > 128 * 1024) ? size - 128 * 1024 : spoolOffset
        // A read that begins mid-file begins mid-line; that fragment is not a
        // record and must not be parsed as one.
        var skipFirst = start > 0

        let consumed = TailRead.consumeLines(handle: handle, fromOffset: start) { [weak self] line in
            if skipFirst {
                skipFirst = false
                return
            }
            guard let self, let event = CommandCodeHookEvent.parse(line: line) else { return }
            self.apply(event: event, now: now)
        }

        spoolOffset = start + consumed
    }

    private func apply(event: CommandCodeHookEvent, now: Date) {
        let id = event.sessionID
        var record = records[id] ?? SessionRecord(
            id: id,
            transcriptPath: event.transcriptPath ?? "",
            projectDir: event.cwd,
            now: now
        )

        if !event.cwd.isEmpty { record.projectDir = event.cwd }
        if let path = event.transcriptPath, !path.isEmpty { record.transcriptPath = path }
        if let pid = event.pid { record.pid = pid }
        if let tty = event.tty, !tty.isEmpty { record.tty = tty }

        switch event.kind {
        case .sessionStart:
            record.apply(status: .idle, at: event.at, activity: nil)
            if record.startedAt == nil { record.startedAt = event.at }
            record.endedAt = nil

        case .preToolUse:
            // The hook already extracted the one argument worth naming, so the
            // Swift side only has to phrase it.
            let activity = ToolActivity.phrase(tool: event.toolName ?? "", detail: event.detail)
                ?? event.toolDisplayName
            record.lastTool = event.toolName
            record.apply(status: .working, at: event.at, activity: activity)

        case .postToolUse:
            // A tool returning does not end the turn — the model still has to
            // react to the result. Status stays `working`; only the clock moves.
            record.lastTool = event.toolName ?? record.lastTool
            record.apply(status: .working, at: event.at, activity: record.activity)

        case .stop:
            // The one unambiguous "turn is over" signal available locally.
            record.apply(status: .completed, at: event.at, activity: nil)
            record.endedAt = event.at
        }

        record.lastEvidenceAt = max(record.lastEvidenceAt, event.at)
        records[id] = record
    }

    // MARK: - Discovery

    private func discover(now: Date, activeWindow: TimeInterval) {
        let fileManager = FileManager.default
        let projectsURL = CommandCodePaths.projectsURL

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Anything written inside the active window, plus anything a hook has
        // already told us about (which may be in a project dir we have not
        // scanned yet).
        var candidatePaths: [String] = []

        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                let name = file.lastPathComponent
                guard CommandCodePaths.isTranscriptFile(name) else { continue }

                let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey,
                ])
                let modified = values?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) < activeWindow else { continue }

                candidatePaths.append(file.path)
            }
        }

        // Sessions a hook mentioned but whose directory scan missed.
        for record in records.values where !record.transcriptPath.isEmpty {
            if !candidatePaths.contains(record.transcriptPath) {
                candidatePaths.append(record.transcriptPath)
            }
        }

        for path in candidatePaths {
            tail(path: path, now: now)
        }
    }

    private func tail(path: String, now: Date) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? now

        // Identity is the transcript path until the header tells us the id.
        let existingKey = records.first { $0.value.transcriptPath == path }?.key
        var record = existingKey.flatMap { records[$0] } ?? SessionRecord(
            id: UUID().uuidString,
            transcriptPath: path,
            projectDir: (path as NSString).deletingLastPathComponent,
            now: now
        )

        // Only pay for a re-read when the file actually moved.
        guard record.fileSize != size || record.state.isFirstConsume else {
            records[record.id] = record
            return
        }

        CommandCodeSessionReader.consume(path: path, size: size, state: &record.state)
        record.fileSize = size
        record.modifiedAt = modified

        if let id = record.state.id, id != record.id, records[id] == nil {
            // The header named the session — re-key under its real id so hook
            // events (which carry the same id) land on this record.
            records.removeValue(forKey: record.id)
            record.id = id
        }

        if let cwd = record.state.cwd, !cwd.isEmpty { record.projectDir = cwd }
        if let started = record.state.startedAt { record.startedAt = started }

        record.applyTranscriptEvidence(now: now)
        record.loadTitleIfNeeded()

        records[record.id] = record
    }

    // MARK: - Spotlight

    private func detectSpotlight(in sessions: [CommandCodeSession], now: Date) -> Spotlight? {
        var found: Spotlight?
        var next: [String: CommandCodeStatus] = [:]

        for session in sessions {
            next[session.id] = session.status
            let previous = lastPublishedStatus[session.id]

            // Only a genuine working → finished edge is worth interrupting for.
            if session.status == .completed, previous == .working {
                found = Spotlight(kind: .finished, sessionID: session.id, at: now)
            }
        }

        lastPublishedStatus = next
        return found
    }

    private func scheduleSpotlightClear(id: String, at: Date) {
        spotlightClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.spotlight?.sessionID == id else { return }
            self.spotlight = nil
        }
        spotlightClearWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Pref.spotlightSeconds,
            execute: work
        )
    }

    // MARK: - Summary

    /// `HookInstaller.currentState()` stats a script and parses
    /// `settings.json`. That is cheap but not free, and it is on the 1.2s
    /// polling path — so it is sampled, not re-derived every tick. Installing
    /// or removing hooks calls `invalidate()`, which resets this.
    private func cachedHookState(now: Date) -> Bool {
        if now.timeIntervalSince(hookStateCache.at) < 15 {
            return hookStateCache.installed
        }
        let installed = HookInstaller.currentState() == .installed
        hookStateCache = (installed, now)
        return installed
    }

    private static func summarize(_ sessions: [CommandCodeSession]) -> CommandCodeSummary {
        guard !sessions.isEmpty else { return .empty }

        let freshness = Date().addingTimeInterval(-120)
        let loud = sessions
            .filter { $0.lastActivityAt > freshness || $0.status == .working }
            .max { $0.status.attentionRank < $1.status.attentionRank }

        let best = sessions.max { $0.status.attentionRank < $1.status.attentionRank }
        return CommandCodeSummary(
            count: sessions.count,
            status: loud?.status ?? best?.status ?? .idle
        )
    }
}

// MARK: - Record

/// Mutable per-session accumulator. Lives on the monitor's private queue and
/// never escapes it — the published value is the immutable `CommandCodeSession`.
private struct SessionRecord {

    var id: String
    var transcriptPath: String
    var projectDir: String

    var state = TranscriptState()
    var fileSize: UInt64 = 0
    var modifiedAt: Date = .distantPast

    var title: String?
    var titleStamp: Date = .distantPast

    var status: CommandCodeStatus = .unknown
    var statusAt: Date = .distantPast
    var activity: String?
    var lastTool: String?

    var pid: Int32?
    var tty: String?

    var startedAt: Date?
    var endedAt: Date?
    var lastEvidenceAt: Date

    init(id: String, transcriptPath: String, projectDir: String, now: Date) {
        self.id = id
        self.transcriptPath = transcriptPath
        self.projectDir = projectDir
        self.lastEvidenceAt = now
    }

    /// Adopt a status only if the evidence behind it is newer than what we
    /// already have. This is the whole reconciliation rule.
    mutating func apply(status: CommandCodeStatus, at: Date, activity: String?) {
        guard at >= statusAt else { return }
        self.status = status
        self.statusAt = at
        self.activity = activity
    }

    /// A turn boundary read out of the transcript, used when no hook fired.
    mutating func applyTranscriptEvidence(now: Date) {
        guard let entryAt = state.lastEntryAt else { return }
        lastEvidenceAt = max(lastEvidenceAt, entryAt)

        if let activity = state.activity { self.activity = activity }
        if let tool = state.lastTool { lastTool = tool }

        if state.isMidTurn {
            apply(status: .working, at: entryAt, activity: state.activity ?? activity)
        } else if let ended = state.lastTurnEndedAt {
            apply(status: .completed, at: ended, activity: nil)
            endedAt = max(endedAt ?? .distantPast, ended)
        }
    }

    /// `<id>.meta.json` holds the user-facing title. It is tiny but changes
    /// rarely, so it is only re-read when its own mtime moves.
    mutating func loadTitleIfNeeded() {
        guard !transcriptPath.isEmpty else { return }
        let url = CommandCodePaths.metaURL(forTranscript: transcriptPath)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let stamp = attributes[.modificationDate] as? Date,
              stamp > titleStamp
        else { return }

        titleStamp = stamp
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let value = object["title"] as? String, !value.isEmpty {
            title = value
        }
    }

    /// Project to the immutable model, applying recency decay.
    func session(now: Date) -> CommandCodeSession {
        let settled = resolvedStatus(now: now)
        let live = pid.map { $0 > 0 && kill($0, 0) == 0 } ?? false

        return CommandCodeSession(
            id: id,
            projectDir: projectDir,
            transcriptPath: transcriptPath,
            title: title,
            model: state.model,
            status: settled,
            activity: settled == .working ? (activity ?? state.activity) : nil,
            lastPrompt: state.lastPrompt,
            lastTool: lastTool ?? state.lastTool,
            lastAssistantText: state.lastAssistantText,
            startedAt: startedAt ?? state.startedAt ?? lastEvidenceAt,
            lastActivityAt: max(lastEvidenceAt, state.lastEntryAt ?? .distantPast),
            pid: pid,
            tty: tty,
            terminalApp: nil,
            isLive: live
        )
    }

    /// Turns "the turn just ended" into an honest resting state.
    ///
    /// `completed` is a flash, not a condition: after a few seconds the
    /// session is simply waiting for you. After a long quiet spell it is idle.
    /// `working` is never decayed on a timer alone — it is backed by evidence
    /// (a turn is open), and inventing idleness mid-tool-call would be a lie.
    /// It is only demoted when the evidence goes stale *and* no process
    /// answers, which means Command Code died mid-turn.
    private func resolvedStatus(now: Date) -> CommandCodeStatus {
        switch status {
        case .completed:
            let quiet = now.timeIntervalSince(statusAt)
            if quiet < Pref.completedFlashSeconds { return .completed }
            if quiet < Pref.idleAfterSeconds { return .waiting }
            return .idle

        case .working:
            let quiet = now.timeIntervalSince(statusAt)
            if quiet > Pref.staleWorkingSeconds {
                if let pid, kill(pid, 0) == 0 { return .working }
                return .unknown
            }
            return .working

        case .waiting:
            return now.timeIntervalSince(statusAt) < Pref.idleAfterSeconds ? .waiting : .idle

        case .idle, .unknown:
            return status
        }
    }
}
