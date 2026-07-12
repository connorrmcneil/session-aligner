# session-aligner improvement plan (Ralph loop backlog)

Work top to bottom. One task per iteration. Context on WHY each task exists is
in the task text — trust it, the review that produced it read the whole codebase.

Goal state: a reliable, tested, security-clean, multi-provider tool that aligns
the 5-hour usage windows of BOTH Claude Code and OpenAI Codex (v0.3.0), with a
recruiter-ready README. Claude pings drive the interactive TUI via expect
(headless `claude -p` stopped counting toward the subscription window in June
2026); Codex pings are headless `codex exec --json` (headless DOES count on
ChatGPT-plan auth, and the JSON output includes
`rate_limits.primary.{used_percent,window_minutes,resets_in_seconds}` — though
some versions emit `rate_limits: null`, so UNCONFIRMED handling stays).

## M1 — Tests + CI (safety net; no behavior changes)

- [ ] M1.1 Add bats-core scaffolding: tests/ dir, a helpers.bash that sources
      individual functions from the scripts without executing their main
      bodies (aligner.sh dispatches at the bottom — source with a guard or
      extract via `sed`), plus a README note in tests/ on how to run.
- [ ] M1.2 Wrap all BSD-only date calls (`date -j`, `date -v`, `date -r`,
      `stat -f`) in tiny named wrapper functions (e.g. date_parse, date_add_days,
      date_from_epoch) with identical behavior on macOS. Pure mechanical
      refactor; no logic changes. This makes the logic testable on Linux CI.
- [ ] M1.3 Unit tests for parse_reset_epoch (ping.sh): "Resets 3:10pm",
      "Resets3:10pm", "Resets 3pm" (no minutes), 12:00am and 12:00pm,
      after-midnight rollover (+1 day), >7h-away rejection, garbage input,
      case variations. Stub the date wrappers from M1.2.
- [ ] M1.4 Unit tests for classification boundaries in run_one_ping using
      FAKE_CLEAN + FORCE_RESET_EPOCH + FORCE_START_EPOCH: exactly at
      RETRY_GRACE_MIN => OLD, exactly at FRESH_MIN_MIN (270) => FRESH, between
      => USED, missing reset => UNCONFIRMED, slow-ping case (start-time
      classification, the v0.1.1 regression).
- [ ] M1.5 Unit tests for validate_times (rejects 24:00, 9:5, empty; accepts
      9:05, 23:59), validate_int, config clamping in load_config (out-of-range
      and non-numeric values for every clamped var).
- [ ] M1.6 Unit tests for preflight_times (incl. midnight clamp as CURRENTLY
      implemented — document current behavior, M3 changes it) and for
      schedule-wakes.sh wake generation under DRY_RUN=1 (weekday skipping,
      already-passed skipping).
- [ ] M1.7 Golden-file tests for build_plist, build_wake_plist,
      build_preflight_plist (every-day and weekday modes). On Linux, compare
      strings; add `plutil -lint` only when running on macOS (`uname` guard).
- [ ] M1.8 GitHub Actions workflow .github/workflows/ci.yml: job 1 shellcheck
      (all shell scripts), job 2 bats on ubuntu-latest, job 3 bats + plutil on
      macos-14. Add CI + license badges to README top.

## M2 — Security fix: root daemon must not trust user-writable files (v0.2.0)

- [ ] M2.1 Add a safe config reader function (shared or duplicated per script:
      grep KEY= + strip quotes + validate numeric/enum, like state_get in
      aligner.sh) and replace ALL `. "$CONFIG_FILE"` sourcing in aligner.sh,
      ping.sh, schedule-wakes.sh, preflight-awake.sh with it. Add a test that
      a config line like `TIMES="05:00"; touch /tmp/pwned` cannot execute code.
- [ ] M2.2 Change `wake on` (cmd_wake in aligner.sh) to install schedule-wakes.sh
      to a root-owned copy at /Library/Application Support/SessionAligner/
      (install -o root -g wheel -m 755 inside the existing single sudo block)
      and point the LaunchDaemon plist at that copy. The daemon must read
      config via the M2.1 safe reader from a PATH ARGUMENT, never source it.
- [ ] M2.3 Handle migration: `wake on` replaces any old plist pointing into the
      repo; `wake off` and `uninstall` remove the root-owned copy and its dir.
      Update the README note that said "don't move the folder".
- [ ] M2.4 Add SECURITY.md describing the threat model and the fix. Bump
      VERSION to 0.2.0, add CHANGELOG entry.

## M3 — Correctness bugs

- [ ] M3.1 cmd_times (and the setup path) must rebuild the preflight agent when
      preflight_installed, so changed times don't leave stale caffeinate
      schedules. Add a test asserting the generated preflight plist matches new
      times after cmd_times.
- [ ] M3.2 upcoming_wake_epochs / already_scheduled: accept both 2-digit and
      4-digit years in pmset output, and only count events this tool scheduled
      (match the full datetime strings we generate; keep a small state list of
      scheduled datetimes written by schedule-wakes.sh so ownership is exact).
      Fix stale_wake_times to only consider owned wakes. Tests with canned
      pmset -g sched fixtures in both year formats.
- [ ] M3.3 Replace the dead timeout/gtimeout outer guard in ping.sh with a
      watchdog that works on stock macOS: run expect in background, `sleep 180
      && kill` guard (or expect's own absolute timeout), preserve the
      FAIL_TIMEOUT classification. Test via a fake slow "claude" stub script.
- [ ] M3.4 TOKENS extraction (python3 block in ping.sh): remove the global
      fallback that scans ALL ~/.claude/projects; only read the aligner's own
      project dir, and if empty log "tokens unavailable" instead of possibly
      reporting another session's reply. Test with a fixture project dir.
- [ ] M3.5 Add an mkdir lock to ping.sh (mirror the schedule-wakes.sh lock,
      including stale-lock cleanup sized to the max retry hold ~25 min) so a
      manual test can't interleave with a scheduled ping.
- [ ] M3.6 Fix midnight wrap: a wake time that goes negative must land on the
      PREVIOUS day (schedule-wakes.sh full datetime math; for the preflight
      StartCalendarInterval compute the wrapped HH:MM and, in weekday mode,
      the shifted weekday). Update the M1.6 test that pinned old behavior.
- [ ] M3.7 Clamp FRESH_MIN_MIN after config load in ping.sh (range 60-330,
      default 270). Test non-numeric and out-of-range values.
- [ ] M3.8 Tighten FAIL_LOGIN detection to real login-screen phrases anchored
      to the pre-reply portion of output, so footer text containing "/login"
      can't misclassify a successful ping. Add fixture-based tests for
      FAIL_LOGIN, FAIL_NET, FAIL_START, and a false-positive case.
- [ ] M3.9 times/setup: warn (not reject) when consecutive start times are
      < 5h apart ("second window will always find the first still active");
      dedupe and sort input times. Tests.

## M4 — macOS-native state layout

- [ ] M4.1 Introduce path resolution: config -> ~/Library/Application Support/
      SessionAligner/, logs -> ~/Library/Logs/SessionAligner/, state file with
      config. One function defines all paths; every script uses it. Env var
      override (SESSION_ALIGNER_HOME) for tests.
- [ ] M4.2 One-time migration on any command: if legacy files exist in the repo
      dir, move them, print a notice. Uninstall removes the new dirs (and the
      state file — currently forgotten). Tests for fresh, legacy, and
      already-migrated states.
- [ ] M4.3 Size-capped log rotation (e.g. >1MB -> keep one .old) applied on
      write in the log() helpers. Tests.
- [ ] M4.4 Replace deprecated launchctl load/unload with bootstrap/bootout
      gui/$UID for the user agents (keep the existing fallback pattern used by
      the daemon path).
- [ ] M4.5 Write a machine-readable outcome line per ping (single line,
      key=value, including a provider= field) to a dedicated outcomes file;
      make count_recent_pings / last_log_summary / auth signal read THAT
      instead of grepping prose. Keep prose logs for humans. Tests for the
      readers.

## M5 — Multi-provider: Codex support (v0.3.0)

Design (decided; do not relitigate): a provider contract in providers/<id>.sh
with four functions — provider_find_bin, provider_creds_present
(present|absent|unknown; Codex checks ~/.codex/auth.json), provider_send_ping
(sets RESET_EPOCH or empty, PROOF_LINE, and FAIL_* outcome on failure), and
provider_login_hint. Shared code owns classification (FRESH/OLD/USED from
RESET_EPOCH vs PING_START_EPOCH — thresholds unchanged), retry, wake/preflight,
state, and logging. Schedules: shared TIMES default with optional per-provider
CLAUDE_TIMES / CODEX_TIMES overrides; wake and preflight use the UNION of all
enabled providers' times (dedup after applying the wake lead). PROVIDERS
defaults to "claude" so existing installs are unchanged.

- [ ] M5.1 Split aligner.sh into lib/*.sh modules (config, launchd, wake,
      health, ui) sourced by a thin aligner.sh dispatcher. No behavior change;
      all tests stay green; shellcheck covers the new files.
- [ ] M5.2 Define the provider contract; extract the existing Claude logic
      (find_claude, claude_creds_present, the expect/ping.exp spawn +
      parse_reset_epoch + TOKENS extraction) into providers/claude.sh behind
      it; ping.sh takes a provider argument (default claude) and becomes the
      shared driver. No behavior change; tests green.
- [ ] M5.3 Add PROVIDERS + per-provider TIMES to config (via the M2.1 safe
      reader), a `providers` subcommand (list / enable codex / disable codex),
      and `times --provider <id> "<times>"` plus `times --provider <id>
      default` to clear an override. Effective-times helper: provider override
      else shared TIMES. Tests for parsing, fallback, enable/disable.
- [ ] M5.4 Per-provider ping LaunchAgents (com.sessionaligner.ping.claude /
      .codex, ProgramArguments: ping.sh <provider>) with migration that
      removes the legacy unsuffixed com.sessionaligner.ping plist. Wake daemon
      and preflight plist use the union of enabled providers' effective times.
      Golden-file plist tests incl. two-provider union and dedup.
- [ ] M5.5 Implement providers/codex.sh: bin discovery (codex in PATH,
      /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, npm global),
      ~/.codex/auth.json creds check, ping via `codex exec --json
      --skip-git-repo-check "hi"` under the M3.3 watchdog, python3 parser for
      the last token_count event (RESET_EPOCH = now + primary.resets_in_seconds;
      PROOF_LINE with primary/secondary used_percent + tokens; null or missing
      rate_limits => UNCONFIRMED; tolerate unknown fields), failure mapping
      (auth error => FAIL_LOGIN, network => FAIL_NET, spawn => FAIL_START),
      optional CODEX_MODEL config, login hint "run: codex login". Unit tests
      against fixture JSONL in tests/fixtures/codex/ (fresh window, mid-window,
      null rate_limits, auth error, network error) plus a fake `codex` stub
      binary for the end-to-end path. NEVER invoke a real codex binary in tests.
- [ ] M5.6 Per-provider auth state keys (LAST_AUTH_OK_EPOCH_CODEX etc. — keep
      legacy unsuffixed keys reading as claude's) and provider tagging in the
      M4.5 outcome records; update count_recent_pings / last_log_summary /
      last_ping_auth_signal / auth_state to take a provider. Tests.
- [ ] M5.7 Provider awareness in status/report/doctor/setup/test: per-provider
      sections (binary, auth, last ping, tally, next start), provider-tagged
      warnings ("[codex] last ping FAILED..."), setup detects installed
      binaries and offers enabling each, `test` pings all enabled providers
      and `test codex` pings one. Snapshot tests for report with 1 and 2
      providers enabled.
- [ ] M5.8 Docs for multi-provider: docs/commands.md (providers, times
      --provider, test <provider>), CHANGELOG v0.3.0, VERSION bump, README
      one-liner and TL;DR mention both Claude Code and Codex (full README
      rewrite stays in M7).

## M6 — Polish & observability

- [ ] M6.1 `report --json` emitting the same fields as report (per provider).
      Test the JSON with python3 -m json.tool.
- [ ] M6.2 Warning in report when a provider's last 3 outcomes are UNCONFIRMED:
      "the <provider> CLI output format may have changed". Test.
- [ ] M6.3 Cleanups: single source of truth for the Claude model name (ping
      MODEL var vs ping.exp hardcode), remove duplicated "Ping times" line in
      status, anchor the is_installed label grep, uninstall removes the state
      file (if not already done in M4.2).
- [ ] M6.4 CHANGELOG finalized; ensure VERSION/README/docs agree (add a test
      that greps them for the same version string).

## M7 — Launch polish

- [ ] M7.1 Rewrite README to the agreed structure: one-line pitch ("align
      Claude Code AND Codex usage windows"), badges, demo GIF placeholder, Why
      (ONE disclaimer), How it works (Mermaid sequence diagram incl. both
      provider paths), Install (4 lines), Usage (trimmed table), Verify,
      Reliability notes, Development, FAQ. Move deep-dive prose to
      docs/architecture.md and docs/faq.md; keep README under ~150 lines.
- [ ] M7.2 Add docs/architecture.md (component table, timeline diagram,
      provider contract, failure/classification model) and docs/faq.md
      (usage-doesn't-move, duplicate wakes, why Claude needs interactive but
      Codex doesn't, wake-vs-ping time).
- [ ] M7.3 Add CONTRIBUTING.md (how to run tests/shellcheck, DRY_RUN hooks,
      how to add a provider) and .github/ISSUE_TEMPLATE (bug report asks for
      `report` output + macOS version + provider).
- [ ] M7.4 Add a scripts/demo.tape (vhs) or demo script that stages fixture
      logs and records setup -> test -> report for the README GIF (GIF itself
      is recorded manually on a Mac; the tape must be runnable).

## Iteration log
<!-- Ralph iterations append one line each below. Never edit existing lines. -->
