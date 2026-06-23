# Session Aligner — Command Reference

This document lists every command, what it does, when to use it, and whether it
needs your Mac password.

Throughout this guide, commands are written as `session-aligner <command>`. If you
did not run `./install.sh`, use `./aligner.sh` instead from the project folder
(for example `./aligner.sh status`).

---

## Quick reference

| Command | What it does | Needs password? |
| --- | --- | --- |
| `./install.sh` | Install the global `session-aligner` command | Sometimes (for `/usr/local/bin`) |
| `session-aligner setup` | Guided first-time setup | Only if you enable auto-wake |
| `session-aligner status` | Friendly overview of schedule + health | No |
| `session-aligner status --raw` | Same as status, plus raw `pmset` output | No |
| `session-aligner report` | Full health summary + warnings (best quick check) | No |
| `session-aligner version` / `--version` / `-v` | Print the version (`session-aligner 0.1.0`) | No |
| `session-aligner test` | Send one tiny ping right now | No |
| `session-aligner times "..."` | Change window start times | No |
| `session-aligner start` | Turn the schedule ON | No |
| `session-aligner stop` | Turn the schedule OFF | No |
| `session-aligner on` | Same as `start` | No |
| `session-aligner off` | Same as `stop` | No |
| `session-aligner next` | Show next window start and next wake | No |
| `session-aligner wake on` | Enable auto-wake + preflight keep-awake before each window start | Yes (once) |
| `session-aligner wake off` | Remove auto-wake helper, preflight agent, and cancel wakes | Yes |
| `session-aligner wake status` | Show helpers, wake lead, keep-awake, wake/ping times, upcoming wakes | No |
| `session-aligner wake status --raw` | Same, plus raw `pmset` output | No |
| `session-aligner wake lead <min>` | Set how early the Mac wakes (1-60, default 15) | Yes, if auto-wake is installed |
| `session-aligner wake keep-awake <min>` | Set the preflight caffeinate duration (5-90, default 20) | No |
| `session-aligner retry status` | Show retry-after-reset settings | No |
| `session-aligner retry on` | Recover when the old window is still active at ping time | No |
| `session-aligner retry off` | Report fresh/old/used honestly but never auto-retry | No |
| `session-aligner retry grace <min>` | Reset within this means OLD window (1-60, default 20) | No |
| `session-aligner retry after-reset <sec>` | Wait this long past the reset before re-pinging (0-600, default 60) | No |
| `session-aligner doctor` | Diagnose common setup problems | No |
| `session-aligner check` | Same as `doctor` | No |
| `session-aligner repair` | Fix common problems (reload agents, chmod) | Yes, if auto-wake is installed |
| `session-aligner logs` | Show recent activity from all logs | No |
| `session-aligner logs ping` | Show recent ping log only | No |
| `session-aligner logs wake` | Show recent wake log only | No |
| `session-aligner logs daemon` | Show wake daemon log only | No |
| `session-aligner logs preflight` | Show preflight keep-awake log only | No |
| `session-aligner uninstall` | Stop schedule, remove auto-wake, optional cleanup | Yes, if auto-wake is installed |
| `session-aligner help` | Show built-in help | No |

---

## Install

### `./install.sh`

**What it does:** One-time installer. Makes scripts executable, checks requirements
(macOS, Claude Code, `expect`), and creates a global command at
`/usr/local/bin/session-aligner` pointing to this project's `aligner.sh`.

**When to use it:** First time you set up Session Aligner, or after cloning the
repo to a new machine.

**Example:**

```bash
cd /path/to/session-aligner
./install.sh
```

**Notes:**

- May ask for your Mac password once if `/usr/local/bin` is owned by the system.
- If the global command cannot be created, you can still use `./aligner.sh` from
  this folder.
- Offers to run guided setup (`session-aligner setup`) when finished.

---

## Setup and schedule

### `session-aligner setup`

**What it does:** Interactive guided setup. Walks you through:

1. Using the recommended window starts (`05:00 10:00 15:00`) or custom times
2. Every day vs weekdays only
3. Whether to enable auto-wake before each window start

**When to use it:** First time, or when you want to reconfigure everything from
scratch.

**Example:**

```bash
session-aligner setup
```

**Notes:**

- Does **not** increase your Claude usage — it only lines up when the 5-hour
  window starts.
- Window start times are **START** times. `05:00` starts a Claude window around
  05:00 by sending a tiny interactive ping.
- If you choose auto-wake, it runs `wake on` and asks for your password once.

---

### `session-aligner times "05:00 10:00 15:00"`

**What it does:** Changes your Claude window start times. Keeps your current
days setting (every day vs weekdays). Reloads the ping schedule if it is ON.

**When to use it:** You want different start times without going through full
setup again.

**Example:**

```bash
session-aligner times "06:00 11:00 16:00"
```

**Notes:**

- Times must be 24-hour `HH:MM`, space-separated.
- If auto-wake is ON, new wake times are picked up within an hour, or run
  `session-aligner wake on` to apply immediately.

---

### `session-aligner start` / `session-aligner stop`

**What it does:**

- `start` — enables the ping schedule using your saved times and days.
- `stop` — disables the ping schedule but remembers your settings.

**Aliases:** `on` (= start), `off` (= stop)

**When to use it:** Pause Session Aligner temporarily, or turn it back on after
stopping.

**Examples:**

```bash
session-aligner stop
session-aligner start
```

**Notes:**

- Stopping the schedule does **not** remove auto-wake. Use `wake off` separately
  if you want to stop scheduled wakes too.

---

## Testing and status

### `session-aligner test`

**What it does:** Sends one tiny interactive Claude Code ping right now. This
starts (or continues) a Claude 5-hour window immediately.

**When to use it:** Verify Claude Code is logged in, `expect` works, and pings
succeed before relying on the schedule.

**Example:**

```bash
session-aligner test
```

**Notes:**

- Check `aligner.log` or `session-aligner logs ping` for `SUCCESS` and `TOKENS:`
  lines as proof the ping worked.
- Does not need admin access.

---

### `session-aligner status`

**What it does:** Friendly overview: schedule on/off, auto-wake on/off, days,
window starts, ping times, wake lead, keep-awake duration, computed wake times,
next start, next wake, Claude Code path, power state, last ping, last wake refresh,
and upcoming wakes.

**When to use it:** Daily check that everything looks right.

**Example:**

```bash
session-aligner status
session-aligner status --raw    # append raw pmset -g sched output
```

---

### `session-aligner report`

**What it does:** A fuller, scan-friendly health summary — the best single command
for checking whether the tool is healthy and recent pings are working. On top of the
`status` fields it adds the **version**, **preflight** and **retry** state, a count of
**recent ping outcomes** from the log, and a **Warnings** section.

The recent-ping tally reads the last 50 outcome lines from `aligner.log` and reports:

```text
Recent pings:   8 fresh, 0 old-window, 0 used-existing, 0 unconfirmed, 0 failures
```

- **fresh** — `FRESH WINDOW STARTED` (a new 5-hour window opened)
- **old-window** — `OLD WINDOW ACTIVE` (old window still active; a retry follows)
- **used-existing** — `USED EXISTING WINDOW` (ping rode an existing window)
- **unconfirmed** — `PING SENT (UNCONFIRMED)` (couldn't read `/usage`)
- **failures** — `FAILURE` (timeout, not logged in, network/startup error)

**Warnings** appear only when relevant — e.g. the Mac is on battery, the schedule /
auto-wake / preflight is off, Claude Code is missing, the last ping wasn't a fresh
window, there are no recent pings, or **stale wake entries** are detected (wake times
in `pmset` that don't match the current wake lead, usually left over from an older
lead — fix with `wake off && wake on`). `report` is informational and always exits 0,
even when warnings are present.

**When to use it:** Your go-to "is everything okay?" check, and the first thing to run
if a window didn't start when you expected.

**Example:**

```bash
session-aligner report
```

---

### `session-aligner version`

**What it does:** Prints the version, e.g. `session-aligner 0.1.0`. Also available as
`--version` and `-v`.

**Example:**

```bash
session-aligner --version
```

---

### `session-aligner next`

**What it does:** Shows only the next Claude window start and next scheduled
wake (if auto-wake is on).

**When to use it:** Quick glance at what's coming up.

**Example:**

```bash
session-aligner next
```

---

## Auto-wake

Auto-wake makes your Mac wake **15 minutes before** each window start (the
configurable *wake lead*) so pings can fire even while the Mac is asleep (lid
closed + plugged in). The **ping** still fires at the exact window start — only the
*wake* is early, to give macOS time to come fully awake.

To stop the Mac dozing off again between the early wake and the ping, auto-wake also
installs a **preflight keep-awake** LaunchAgent (`com.sessionaligner.preflight`, runs
as you — no admin needed) that runs `caffeinate -dimsu` for 20 minutes at each wake
time. Timeline (defaults): **04:45** wake + caffeinate → **05:00** ping → **05:05**
caffeinate expires.

### `session-aligner wake on`

**What it does:** Installs a root background helper (`com.sessionaligner.wake`)
that keeps one-time `pmset` wake events scheduled `WAKE_LEAD_MIN` minutes before each
window start, and a user-level preflight keep-awake agent
(`com.sessionaligner.preflight`). Seeds wakes immediately.

**When to use it:** Your Mac may be asleep at a window start time (especially
overnight).

**Example:**

```bash
session-aligner wake on
```

**Why it asks for your password:** macOS requires admin/root access to schedule
system wake events via `pmset`. Your password is handled by macOS `sudo` and is
**not** stored by Session Aligner. The helper only manages wake times — it does
not use your Claude account. The normal ping schedule runs as you and needs no
admin access.

---

### `session-aligner wake off`

**What it does:** Removes the auto-wake helper and the preflight keep-awake agent,
cancels scheduled wake events created by Session Aligner, and cancels any old
repeating wake.

**When to use it:** You no longer want the Mac to wake itself for window starts.

**Example:**

```bash
session-aligner wake off
```

**Notes:** Asks for your Mac password (admin access to remove the LaunchDaemon
and cancel `pmset` events).

---

### `session-aligner wake status`

**What it does:** Shows whether the auto-wake helper and preflight keep-awake agent
are installed, plus the window starts, wake lead, keep-awake duration, computed wake
times and ping times, and the upcoming wakes in human-readable form
(`today at 14:45`, etc.).

**Example:**

```bash
session-aligner wake status
session-aligner wake status --raw    # append raw pmset -g sched output
```

---

### `session-aligner wake lead <min>`

**What it does:** Sets how many minutes before each window start the Mac wakes
(`WAKE_LEAD_MIN`, range 1-60, default 15). If auto-wake is installed it re-applies
immediately (re-seeds `pmset` wakes and rebuilds the preflight agent); otherwise the
new value applies next time you run `wake on`. If the current keep-awake duration is
not longer than the new lead, it is automatically raised to `lead + 5` so
`caffeinate` still spans past the ping.

**Example:**

```bash
session-aligner wake lead 15
session-aligner wake lead 20
```

---

### `session-aligner wake keep-awake <min>`

**What it does:** Sets how long the preflight `caffeinate` keeps the Mac awake
(`KEEP_AWAKE_MIN`, range 5-90, default 20). The preflight script reads this at run
time, so the change takes effect at the next wake with no admin access needed. Values
not greater than the wake lead are raised to `lead + 5` (otherwise caffeinate would
expire before the ping fires).

**Example:**

```bash
session-aligner wake keep-awake 20
session-aligner wake keep-awake 25
```

---

## Retry after an active old window

A ping only starts a *fresh* 5-hour window if no window is currently active. If an
earlier ping ran a little late, its window can still be running when the next ping
fires — so that ping just rides the old window instead of opening a new one. To tell
the difference, after each ping the tool reads the `/usage` reset time and classifies
the result:

| Outcome | Meaning | Reset time seen |
|---------|---------|-----------------|
| `FRESH WINDOW STARTED` | A new 5-hour window opened | ~4.5–5 hours away |
| `OLD WINDOW ACTIVE` | Old window still running, about to reset | within `RETRY_GRACE_MIN` (default 20 min) |
| `USED EXISTING WINDOW` | Ping landed mid-window; no fresh window, no retry needed | between the grace and ~4.5 h |
| `PING SENT (UNCONFIRMED)` | Claude replied but the reset time couldn't be parsed | (unreadable) |
| `FAILURE` | Timeout, not logged in, network/startup error, missing command | (n/a) |

When the result is `OLD WINDOW ACTIVE` **and** retry is enabled, the tool keeps the
Mac awake with `caffeinate` until `RETRY_AFTER_RESET_SEC` (default 60) past the reset,
then pings **once** more so the fresh window opens. The retry is one-time: it never
loops or reschedules, and it logs the second result honestly even if it still isn't
fresh. The wait is bounded (≈ grace + after-reset + a small buffer), and a reset more
than ~7 hours away is treated as `UNCONFIRMED` rather than a retry target, so a bad
parse can never make the script sleep for hours. **Configured ping times never move.**

These show up in `session-aligner status` (the `Last ping:` line reads `FRESH`,
`OLD-WINDOW`, `USED-EXISTING`, `UNCONFIRMED`, or `FAILURE`) and in
`session-aligner logs ping` (full detail).

### `session-aligner retry status`

**What it does:** Shows whether retry is on, the grace window, and the
after-reset wait.

### `session-aligner retry on` / `off`

**What it does:** Enables or disables the one-time recovery retry
(`RETRY_AFTER_ACTIVE_WINDOW`). With it off, pings are still classified honestly —
they just won't auto-retry.

### `session-aligner retry grace <min>`

**What it does:** Sets `RETRY_GRACE_MIN` (1–60, default 20). A `/usage` reset within
this many minutes counts as an OLD window still active (and triggers a retry when
enabled).

### `session-aligner retry after-reset <sec>`

**What it does:** Sets `RETRY_AFTER_RESET_SEC` (0–600, default 60) — how long past the
reset to wait before re-pinging, so the old window has definitely closed.

```bash
session-aligner retry status
session-aligner retry off
session-aligner retry grace 20
session-aligner retry after-reset 60
```

---

## Diagnostics and maintenance

### `session-aligner doctor`

**What it does:** Runs a checklist: macOS, Claude Code, `expect`, script files,
executables, ping schedule installed/loaded, auto-wake installed, upcoming wakes,
power state, config. Prints numbered suggested fixes if anything is wrong.

**Alias:** `check`

**When to use it:** Something isn't working and you want a quick diagnosis.

**Example:**

```bash
session-aligner doctor
```

---

### `session-aligner repair`

**What it does:** Safely fixes common issues:

- Makes scripts executable
- Reloads the ping LaunchAgent
- If auto-wake is installed, reloads the wake helper, refreshes upcoming wakes, and
  rebuilds the preflight keep-awake agent

**When to use it:** After moving the project folder, permission issues, or when
`doctor` suggests it.

**Example:**

```bash
session-aligner repair
```

**Notes:** Does not change your configured times. If auto-wake is installed,
reload may ask for your password.

---

### `session-aligner logs`

**What it does:** Shows the last several lines from activity logs.

**Examples:**

```bash
session-aligner logs           # all logs (ping, wake, daemon)
session-aligner logs ping      # aligner.log only
session-aligner logs wake      # wake.log only
session-aligner logs daemon    # wake.daemon.log only
```

**Log files (in the project folder):**

| File | Contents |
| --- | --- |
| `aligner.log` | Ping results, token usage, SUCCESS/FAILURE |
| `wake.log` | When wakes were scheduled or cancelled |
| `wake.daemon.log` | Output from the auto-wake LaunchDaemon |
| `preflight.log` | Preflight keep-awake start/finish (caffeinate) |
| `aligner.launchd.log` | Output from the ping LaunchAgent |

---

## Uninstall

### `session-aligner uninstall`

**What it does:** Interactive uninstall:

1. Stops the ping schedule
2. Removes the auto-wake helper and preflight keep-awake agent, and cancels scheduled wakes
3. Optionally removes logs and config (default: keep them)
4. Optionally removes `/usr/local/bin/session-aligner` (default: ask)

**When to use it:** You want to fully remove Session Aligner from your Mac.

**Example:**

```bash
session-aligner uninstall
```

**Notes:** Defaults are conservative — logs and config are kept unless you
confirm deletion. Project files in the repo folder are always left in place.

---

## Help

### `session-aligner help`

**What it does:** Prints built-in usage, recommended window start times, and the
`./aligner.sh` fallback note.

**Aliases:** `-h`, `--help`, or running `session-aligner` with no arguments.

**Example:**

```bash
session-aligner help
```

---

## Recommended window starts

Default / recommended:

```
05:00 10:00 15:00
```

These are **START** times — when Session Aligner sends a tiny interactive ping
so a fresh Claude 5-hour window begins:

| Time | Window |
| --- | --- |
| `05:00` | Early morning window |
| `10:00` | Late morning window |
| `15:00` | Afternoon window |

Auto-wake schedules wakes 15 minutes before each (e.g. `04:45`, `09:45`,
`14:45`), and the preflight keep-awake holds the Mac awake through the ping.

This does **not** give you more usage. It only aligns existing windows with your
day.

---

## Manual verification (advanced)

These are system commands, not part of Session Aligner, but useful for debugging:

```bash
which session-aligner
ls -l /usr/local/bin/session-aligner
launchctl list | grep sessionaligner
sudo launchctl print system/com.sessionaligner.wake
pmset -g sched
```
