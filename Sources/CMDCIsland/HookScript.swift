import Foundation

/// The hook script, embedded as a Swift raw string.
///
/// It is written to `~/.commandcode/cmdc-island/hook.mjs` at install time and
/// registered in `~/.commandcode/settings.json`. Command Code runs it on every
/// `PreToolUse`, `PostToolUse`, `Stop` and `SessionStart`.
///
/// Contract, in order of importance:
///
///   1. **Never block the agent.** Writes nothing to stdout, always exits 0 —
///      which Command Code reads as "no opinion, allow".
///   2. **Never throw.** Every path is wrapped; a failure writes nothing.
///   3. **Be fast.** The hot path is one `appendFileSync`. The process walk
///      (which resolves the owning terminal) is cached per session and only
///      recomputed when the cache is missing.
///
/// Node is guaranteed present: Command Code refuses to start below Node 22.
enum HookScript {

    /// File name inside `~/.commandcode/cmdc-island/`.
    static let fileName = "hook.mjs"

    /// Written with `#"""` so JavaScript backslashes and regexes survive
    /// verbatim — a plain Swift multiline literal would eat them.
    static let source = #"""
#!/usr/bin/env node
// CMDC Island — Command Code hook.
// Appends one JSON line per hook event to ~/.commandcode/cmdc-island/events.jsonl
//
// This process must never block the agent: it writes nothing to stdout and
// always exits 0, which Command Code reads as "no opinion, allow".

import { appendFileSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';

const ISLAND = join(homedir(), '.commandcode', 'cmdc-island');
const SPOOL = join(ISLAND, 'events.jsonl');
const PROCS = join(ISLAND, 'proc');

function readStdin() {
  try {
    // Synchronous read of fd 0. Command Code writes the payload and closes.
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

// One line describing what the tool is doing. Mirrors ToolActivity in Swift,
// but only enough for the live status — the transcript remains authoritative.
function detailFor(tool, input) {
  if (!input || typeof input !== 'object') return undefined;
  switch (tool) {
    case 'shell_command':  return firstLine(input.command);
    case 'read_file':
    case 'write_file':
    case 'edit_file':      return baseName(input.file_path || input.absolute_path || input.path);
    case 'read_directory': return baseName(input.path);
    case 'glob':           return firstLine(input.pattern);
    case 'grep':           return firstLine(input.pattern);
    case 'task':           return firstLine(input.description);
    default:               return undefined;
  }
}

function firstLine(value) {
  if (typeof value !== 'string' || !value) return undefined;
  const collapsed = value.replace(/\s+/g, ' ').trim();
  return collapsed.length > 80 ? collapsed.slice(0, 80) : collapsed;
}

function baseName(value) {
  if (typeof value !== 'string' || !value) return undefined;
  const parts = value.split('/');
  return parts[parts.length - 1] || value;
}

// Resolve the pid + tty of the process that owns this hook. The tty is what
// the island focuses when you click; the pid is what it uses to decide whether
// a session is still alive.
//
// The walk is upward, and *which* ancestor we stop at matters. A process
// inherits its controlling terminal across fork/exec, so the shell that runs
// this hook already reports the right tty — and it exits the moment the hook
// finishes. Returning it would cache a pid that is dead by the next poll, so
// liveness would always answer false.
//
// Preference order:
//   1. the nearest ancestor running node — that is Command Code itself, the
//      one process that is alive for exactly as long as the session is;
//   2. otherwise the topmost ancestor with a tty, which is the user's login
//      shell (stable, and survives Command Code restarting inside it);
//   3. otherwise nothing, and focusing falls back to the process table.
//
// Cached per session: a tty never changes mid-session, and this costs one
// `ps` spawn.
function normaliseTTY(value) {
  if (!value || value === '??' || value === '?' || value === '-') return null;
  // BSD ps reports `ttys003`; some builds report the device path.
  return value.replace(/^\/dev\//, '');
}

function isNodeProcess(comm) {
  const base = comm.split('/').pop() || comm;
  return base === 'node' || base === 'node.exe';
}

function rememberOwner(cacheFile, pid, tty) {
  try {
    mkdirSync(PROCS, { recursive: true });
    writeFileSync(cacheFile, pid + ' ' + tty);
  } catch { /* the cache is an optimisation only */ }
}

function resolveOwner(sessionId) {
  const cacheFile = join(PROCS, sessionId);
  try {
    const cached = readFileSync(cacheFile, 'utf8').trim().split(' ');
    if (cached.length >= 2 && cached[1] && cached[1] !== '?') {
      return { pid: Number(cached[0]) || undefined, tty: cached[1] };
    }
  } catch { /* no cache yet */ }

  let table = '';
  try {
    table = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,tty=,comm='], {
      encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    return {};
  }

  const parentOf = new Map();
  const ttyOf = new Map();
  const commOf = new Map();

  // `comm` is last because it is the only field that can contain spaces.
  for (const line of table.split('\n')) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    parentOf.set(pid, Number(match[2]));
    ttyOf.set(pid, match[3]);
    commOf.set(pid, match[4]);
  }

  let pid = process.ppid;
  let topmost = null;

  for (let hop = 0; hop < 32 && pid > 1; hop += 1) {
    const tty = normaliseTTY(ttyOf.get(pid));
    if (tty) {
      if (isNodeProcess(commOf.get(pid) || '')) {
        rememberOwner(cacheFile, pid, tty);
        return { pid, tty };
      }
      topmost = { pid, tty };
    }
    pid = parentOf.get(pid) || 0;
  }

  if (topmost) {
    rememberOwner(cacheFile, topmost.pid, topmost.tty);
    return topmost;
  }
  return {};
}

function main() {
  const text = readStdin();
  if (!text) return;

  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return;
  }
  if (!payload || typeof payload !== 'object') return;

  const event = payload.hook_event_name;
  const sessionId = payload.session_id;
  if (!event || !sessionId) return;

  const tool = payload.tool_name;
  const owner = resolveOwner(sessionId);

  const record = {
    v: 1,
    event,
    sessionId,
    cwd: payload.cwd || '',
    transcript: payload.transcript_path || undefined,
    tool: tool || undefined,
    display: payload.tool_display_name || undefined,
    detail: detailFor(tool, payload.tool_input),
    mode: payload.permission_mode || undefined,
    source: payload.source || undefined,
    pid: owner.pid,
    tty: owner.tty,
    at: Date.now() / 1000,
  };

  try {
    mkdirSync(ISLAND, { recursive: true });
    appendFileSync(SPOOL, JSON.stringify(record) + '\n');
  } catch { /* a missed event must never surface to the agent */ }
}

try {
  main();
} catch { /* never fail loudly — a broken hook would break the agent */ }

process.exit(0);
"""#
}
