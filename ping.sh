#!/usr/bin/env bash
#
# ping.sh - Send one tiny message to Claude Code so a fresh 5-hour SUBSCRIPTION
# session window starts NOW.
#
# IMPORTANT (June 15, 2026 billing change): headless `claude -p` no longer counts
# toward the Pro/Max 5-hour subscription session window - it bills a separate
# metered pool. Only INTERACTIVE Claude Code starts that window. So this script
# drives the real interactive TUI through `expect` (a pseudo-terminal) and types
# one "hi" message. It uses your existing Claude Code login (no API key).
#
# It does NOT increase your quota; it only controls WHEN a 5-hour window begins.
#
# Run it directly to test:  ./ping.sh
# It is also what the launchd schedule runs (installed by ./aligner.sh setup).

set -u

# Resolve the folder this script lives in, so logs and ping.exp are found even
# when launchd/cron runs us from a different working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/aligner.log"
EXP_SCRIPT="${SCRIPT_DIR}/ping.exp"

# launchd/cron run with a tiny PATH that usually does NOT include where
# npm/homebrew put the `claude` binary. Add the common locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/node_modules/.bin:${PATH}"

MODEL="haiku"

# Write a timestamped line to the log AND to the screen.
log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" | tee -a "$LOG_FILE"
}

# Find the claude binary (absolute path), trying PATH first then common spots.
find_claude() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
    return 0
  fi
  for candidate in \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude" \
    "${HOME}/.local/bin/claude" \
    "${HOME}/.claude/local/claude"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CLAUDE_BIN="$(find_claude)" || {
  log "FAILURE: 'claude' command not found. Install Claude Code and run it once to log in."
  exit 1
}

if ! command -v expect >/dev/null 2>&1; then
  log "FAILURE: 'expect' not found (needed for the interactive ping). On macOS it lives at /usr/bin/expect."
  exit 1
fi

if [ ! -f "$EXP_SCRIPT" ]; then
  log "FAILURE: missing ${EXP_SCRIPT}. Reinstall the session-aligner files."
  exit 1
fi

# Outer timeout guard (the expect script also has its own internal timeout).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout 180"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout 180"
fi

log "INFO: sending interactive ping via ${CLAUDE_BIN} (model: ${MODEL})"

# Drive the interactive TUI. Run inside the project folder so the per-folder
# trust prompt (if any) is answered once and remembered for next time.
OUTPUT="$(cd "$SCRIPT_DIR" && $TIMEOUT_BIN expect "$EXP_SCRIPT" "$CLAUDE_BIN" 2>&1)"
STATUS=$?

# Strip ANSI escape codes and control chars so the logged snippet is readable.
# (perl handles \e/\a and hex classes consistently across macOS/Linux; BSD sed
# does not.)
if command -v perl >/dev/null 2>&1; then
  CLEAN="$(printf '%s' "$OUTPUT" | LC_ALL=C perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\e\][^\a]*\a//g; s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g')"
else
  CLEAN="$(printf '%s' "$OUTPUT" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
fi
SNIPPET="$(printf '%s' "$CLEAN" | tr '\n' ' ' | tr -s ' ' | cut -c1-160)"

# --- Proof extraction (best-effort) ---------------------------------------
# 1) Session/reset line from the captured /usage panel. The TUI strips spaces
#    when it renders, so match loosely on "Resets ..." and "NN% used".
SESSION_LINE="$(printf '%s' "$CLEAN" | grep -ioE 'resets[^|]{0,40}' | head -1 | tr -s ' ')"
PCT="$(printf '%s' "$CLEAN" | grep -ioE '[0-9]+% ?used' | head -1)"

# 2) Exact token usage from the transcript this ping just created. The numbers
#    are NOT in /usage; they live in the session JSONL as a `usage` field.
PROJ="${HOME}/.claude/projects/$(printf '%s' "$SCRIPT_DIR" | sed 's#/#-#g')"
TOKENS_LINE=""
if command -v python3 >/dev/null 2>&1; then
  TOKENS_LINE="$(python3 - "$PROJ" <<'PY' 2>/dev/null
import sys, os, glob, json
proj = sys.argv[1]
files = sorted(glob.glob(os.path.join(proj, '*.jsonl')), key=os.path.getmtime) if os.path.isdir(proj) else []
if not files:
    base = os.path.expanduser('~/.claude/projects')
    files = sorted(glob.glob(os.path.join(base, '*', '*.jsonl')), key=os.path.getmtime)
if not files:
    sys.exit(0)
usage = None
reply = ''
for line in open(files[-1]):
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get('type') != 'assistant':
        continue
    msg = o.get('message', {}) if isinstance(o.get('message'), dict) else {}
    u = msg.get('usage')
    c = msg.get('content')
    txt = ''
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'text':
                txt += b.get('text', '')
    if u:
        usage = u
    if txt.strip():
        reply = txt.strip()
if not usage:
    sys.exit(0)
def g(k):
    try:
        return int(usage.get(k, 0) or 0)
    except Exception:
        return 0
reply = reply.replace('\n', ' ')[:80]
print('input=%d output=%d cache_read=%d cache_write=%d | reply: "%s"' % (
    g('input_tokens'), g('output_tokens'),
    g('cache_read_input_tokens'), g('cache_creation_input_tokens'), reply))
PY
)"
fi

# Decide outcome. Interactive exit (Ctrl-C) is normal, so a non-login/non-network
# run that completed is treated as success.
if [ "$STATUS" -eq 124 ]; then
  log "FAILURE: timed out (network problem, or the TUI did not respond). Output: ${SNIPPET}"
  exit 124
elif printf '%s' "$CLEAN" | grep -qiE 'sign ?in|please log ?in|/login|not authenticated|unauthor|authenticate your'; then
  log "FAILURE: not logged in. Open a terminal, run 'claude', then '/login'. Output: ${SNIPPET}"
  exit 1
elif printf '%s' "$CLEAN" | grep -qiE 'network error|offline|could not connect|getaddrinfo|enotfound|dns'; then
  log "FAILURE: network error. Check your internet connection. Output: ${SNIPPET}"
  exit 1
elif printf '%s' "$CLEAN" | grep -qiE 'claude exited before prompt|ERROR: missing path'; then
  log "FAILURE: could not start the interactive session. Output: ${SNIPPET}"
  exit 1
else
  [ -n "$SESSION_LINE" ] && log "SESSION: ${SESSION_LINE}${PCT:+ | ${PCT}}"
  if [ -n "$TOKENS_LINE" ]; then
    log "SUCCESS: interactive ping sent (5-hour window should now be open). TOKENS: ${TOKENS_LINE}"
  else
    log "SUCCESS: interactive ping sent (5-hour window should now be open). Snippet: ${SNIPPET:-(none)}"
    log "INFO: could not read token usage from transcript; verify with /usage in Claude Code."
  fi
  exit 0
fi
