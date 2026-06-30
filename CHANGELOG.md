# Changelog

## v0.1.3 - Public-launch polish

* README launch polish: clearer one-line description and a "does not bypass,
  extend, or increase Claude limits" disclaimer up front.
* Added a "Who this is for" section and a `git clone` quick start (replacing a
  hard-coded local path).
* Expanded "Known limitations": macOS wake reliability, clamshell/battery delays,
  manual re-login (`/login` is never automated), `session-aligner test` sends a
  real ping that may start a window, and what "Auth: OK" really means.
* Added a sample healthy `session-aligner report` output.
* Stopped tracking the local `aligner.config` (added to `.gitignore`) so a fresh
  clone starts from built-in defaults instead of someone else's schedule.

No behavior changes (docs/repo polish only).

## v0.1.2 - Auth health checks

* Added an `Auth:` line to `session-aligner report` (OK / needs login / unknown),
  plus `Last auth OK` and `Last auth failure` timestamps when known.
* Added `session-aligner auth status` (alias `auth check`) - a lightweight,
  non-prompting check of local Claude Code credentials. It never automates login.
* `report` now warns when the last ping failed because Claude Code was not logged
  in, and when auth hasn't been verified by a successful ping in 7+ days.
* Track auth state in a `.session-aligner-state` file: last known-good auth
  (`LAST_AUTH_OK_*`, on a successful ping) and last login failure
  (`LAST_AUTH_FAILURE_*`, on a not-logged-in ping).
* `session-aligner doctor` now includes an auth health check.
* `session-aligner setup` explains the manual Claude Code login up front and
  suggests running `session-aligner test` before relying on overnight pings.

## v0.1.1 - Classification accuracy fix

* Fixed window freshness classification to use the ping **start** time instead of
  the completion/parse time. A slow ping (busy/clamshell Mac, long reply, late
  `/usage` parse) no longer mislabels a window that started fresh as
  `USED EXISTING WINDOW`.
* Added a `WARNING` when a ping takes over 180 seconds to complete, noting that
  classification is based on ping start time.
* Added the `FORCE_START_EPOCH` test hook for late-parse / long-duration runs.

## v0.1.0 - Initial working release

* Added scheduled Claude Code pings at configured window start times.
* Added macOS wake scheduling before each configured window.
* Added preflight keep-awake support using caffeinate.
* Added fresh-window detection from /usage.
* Added one-time retry after an old active window resets.
* Added wake/retry/status/log commands.
* Added version and report commands.
