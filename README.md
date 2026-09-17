# CMDC Island

A Dynamic Island for [Command Code](https://commandcode.ai) on macOS.

A small black pill at the top of the screen that tells you one of three things:

```
● cmd                    Command Code is sitting there
● cmd  Working…          Command Code is working
● cmd  Needs you         Command Code finished and wants you
```

Hover and it opens into the only three lines that matter: what is running, what
it is doing, and where.

```
┌──────────────────────────────────────┐
│ ●  Command Code        deepseek-v4.1 │
│                                      │
│    Editing auth.ts                   │
│    ~/Projects/my-app        Working  │
└──────────────────────────────────────┘
```

Click it and your terminal comes forward, on the right tab.

That is the whole product. There is no dashboard, no token counter, no task
tree, no quota meter, and no cloud service. Everything is local.

---

## Install

Requires macOS 14 or later and Command Code (`cmdc`).

```bash
git clone https://github.com/JakubRasken/cmdc-island.git
cd cmdc-island
./make-app.sh
open "dist/CMDC Island.app"
```

The app is an accessory — no Dock icon. Quit it from the menu bar item.

### Enable live status (recommended)

Open **Settings → Command Code hooks → Install**.

This writes a small Node script to `~/.commandcode/cmdc-island/hook.mjs` and
registers it under the `hooks` key in `~/.commandcode/settings.json`, for the
`PreToolUse`, `PostToolUse`, `Stop` and `SessionStart` events.

The island works without it, but status lags: without hooks the only signal
available is "the transcript file stopped growing", which cannot distinguish a
finished turn from a long tool call.

Installing is conservative by design:

* your `settings.json` is **merged**, never replaced; unknown keys survive,
* a one-time backup is written to `~/.commandcode/cmdc-island/settings.json.backup`,
* if `settings.json` is not valid JSON the install aborts and tells you, rather
  than overwriting a hand-edited file,
* installing twice is a no-op, and **Remove** deletes only its own entries.

---

## How it works

```
Command Code
    │
    ├── hooks (PreToolUse / PostToolUse / Stop / SessionStart)
    │      └── ~/.commandcode/cmdc-island/events.jsonl   ← live status
    │
    └── transcripts
           └── ~/.commandcode/projects/<slug>/<id>.jsonl ← content & structure
                          <id>.meta.json                 ← session title
    │
    ▼
CommandCodeMonitor   (reconciles, on a private queue)
    │
    ▼
Observable session state
    │
    ▼
SwiftUI island
```

Two local sources, one reconciliation rule: **whichever has the newer evidence
wins, per session.**

* **Hooks are authoritative for status.** `Stop` firing is a fact. The hook
  also reports the pid and controlling tty of the Command Code process, found
  by walking the parent chain — that is what makes click-to-focus exact.
* **Transcripts are authoritative for content.** Prompt, tool activity, model,
  title, and turn boundaries when no hook exists.

Nothing is scraped from the terminal, no cloud API is used, and no Command Code
data leaves the machine.

### Where session data is read from

| Path | Used for |
| --- | --- |
| `~/.commandcode/projects/<project-slug>/<session-id>.jsonl` | The transcript |
| `~/.commandcode/projects/<project-slug>/<session-id>.meta.json` | Session title |
| `~/.commandcode/cmdc-island/events.jsonl` | Hook spool (written by us) |
| `~/.commandcode/settings.json` | Hook registration |

### Transcript schema

Verified against real transcripts:

```jsonc
{"type":"session","version":3,"id":"…","timestamp":"…","cwd":"/Users/me/app"}
{"type":"message","id":"…","parentId":null,"timestamp":"…",
 "message":{"role":"user","content":[{"type":"text","text":"…"}]}}
{"type":"message","timestamp":"…","model":"…",
 "message":{"role":"assistant","content":[
    {"type":"text","text":"…"},
    {"type":"thinking","text":"…"},
    {"type":"tool_use","id":"…","name":"edit_file","input":{…}}]}}
{"type":"message","message":{"role":"user","content":[
    {"type":"tool_result","tool_use_id":"…","content":[{"type":"text","text":"…"}]}]}}
{"type":"compaction","id":"…","summary":"…"}
```

Unknown entries and unknown content blocks are skipped, so a future Command Code
version adding records degrades gracefully instead of breaking the island.

### State derivation

| Status | Meaning |
| --- | --- |
| `working` | Inside a turn — tools firing, transcript growing |
| `waiting` | A turn ended recently; Command Code wants you |
| `idle` | Quiet for a while |
| `completed` | The flash right after a turn ends |
| `unknown` | No usable signal |

`working` is never decayed on a timer alone — it is backed by evidence, and
inventing idleness mid-tool-call would be a lie. It is only demoted when the
evidence goes stale *and* no process answers `kill(pid, 0)`, which means
Command Code died mid-turn.

### Performance

* Transcripts are tailed **incrementally** from a remembered byte offset. Only
  complete lines are parsed, so a half-flushed JSON object is never read.
* A cold start reads only the **last 256 KB** of a transcript, never the whole
  file. A 100 MB session costs the same as a 100 KB one.
* Files are only re-read when `size` actually moves.
* `meta.json` (the title) is re-read only when its own mtime moves.
* The event spool is consumed by offset and rotated past 4 MB.
* Polling is a 1.2 s tick doing `stat` calls; all parsing happens on a private
  queue, and the UI is republished only when the snapshot actually differs.

---

## Terminal focusing

The hook resolves the tty of the Command Code process and caches it per session.
Clicking the island uses it to reach the exact tab or pane:

| Terminal | Mechanism | Precision |
| --- | --- | --- |
| tmux | `select-window` / `select-pane` | exact |
| iTerm2 | AppleScript on session tty | exact |
| Terminal.app | AppleScript on tab tty | exact |
| WezTerm | `wezterm cli activate-pane` | exact |
| kitty | `kitten @ focus-window` | exact |
| VS Code, Warp, Ghostty, … | activate the owning app | window-level |

For sessions started before hooks were installed, the tty is resolved on demand
from the process table (`ps` + `lsof`) when you click.

---

## Configuration

Settings cover the island and nothing else:

* **hooks** — install / remove
* **Island** — expand on hover, expand when a session finishes, show model,
  single-session mode
* **Timing** — session retention, how long "Finished" shows, when to go idle
* **Display** — which screen, hide in fullscreen, notch width/height offsets,
  launch at login

Notch width and height offsets exist because the notch geometry differs across
MacBook generations; the defaults are correct on most machines.

---

## Architecture

```
Sources/CMDCIsland/
├── CMDCIslandApp.swift          @main, MenuBarExtra, AppDelegate
├── NotchPanel.swift             borderless top-pinned NSPanel, NotchMetrics
├── NotchShape.swift             the silhouette + content morph transitions
├── IslandView.swift             collapsed / expanded pill
├── Theme.swift                  colours, metrics, type, pulse clock
│
├── CommandCodeMonitor.swift     reconciliation + polling  ← testable headless
├── CommandCodeSession.swift     the session model (in CommandCodeModels.swift)
├── CommandCodeSessionReader.swift   incremental JSONL parser + ToolActivity
├── CommandCodeEventParser.swift     hook spool line parser
├── CommandCodePaths.swift       every path we touch
├── HookScript.swift             the embedded hook, as a Swift raw string
├── HookInstaller.swift          conservative settings.json merge
├── TailRead.swift               incremental, multi-byte-safe line reader
│
├── TerminalFocus.swift          tty → tab/pane
├── ProcessScan.swift            ps / lsof helpers
├── Subprocess.swift             bounded process calls
├── Preferences.swift            all user defaults
├── SettingsView.swift           settings pane
├── SettingsWindow.swift         settings window
└── LoginItem.swift              SMAppService
```

The monitor has no dependency on SwiftUI. It takes files in, produces an
immutable `[CommandCodeSession]`, and can be driven headlessly.

### Reliability

The island tolerates: Command Code not installed or not running, zero sessions,
deleted sessions, malformed lines, a transcript being appended to right now,
multiple simultaneous sessions, rapid state changes, and transcript format
changes.

A malformed line increments a counter and is skipped. A session file that
shrinks (a rewind rewrote it) resets that session's parse state instead of
reading garbage. No single bad file can take the app down.

---

## Not in this app

Deliberately absent, and not planned: Claude Code / Codex / Gemini / OpenCode /
Aider / Goose / Amp / Cursor / Copilot adapters, usage and quota tracking, SSH
and remote monitoring, permission approval flows, multi-agent configuration,
sounds, emoji reactions, and session management UI.

If you want a command centre, [Agents Island](https://github.com/mustafahalabi/agents-island)
is excellent. This is the opposite: one agent, one glance.

---

## Credits

The macOS Dynamic Island infrastructure — the panel geometry, the notch
silhouette, the content morph transitions and the incremental transcript reader —
is adapted from [Agents Island](https://github.com/mustafahalabi/agents-island)
by Mustafa Halabi and Mohammad Hammoud, MIT licensed. See `LICENSE`.

## License

MIT.
