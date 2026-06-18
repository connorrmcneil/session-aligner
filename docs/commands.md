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
| `session-aligner test` | Send one tiny ping right now | No |
| `session-aligner times "..."` | Change window start times | No |
| `session-aligner start` | Turn the schedule ON | No |
| `session-aligner stop` | Turn the schedule OFF | No |
| `session-aligner on` | Same as `start` | No |
| `session-aligner off` | Same as `stop` | No |
| `session-aligner next` | Show next window start and next wake | No |
| `session-aligner wake on` | Enable auto-wake before each window start | Yes (once) |
| `session-aligner wake off` | Remove auto-wake helper and cancel wakes | Yes |
| `session-aligner wake status` | Show auto-wake helper + upcoming wakes | No |
| `session-aligner wake status --raw` | Same, plus raw `pmset` output | No |
| `session-aligner doctor` | Diagnose common setup problems | No |
| `session-aligner check` | Same as `doctor` | No |
| `session-aligner repair` | Fix common problems (reload agents, chmod) | Yes, if auto-wake is installed |
| `session-aligner logs` | Show recent activity from all logs | No |
| `session-aligner logs ping` | Show recent ping log only | No |
| `session-aligner logs wake` | Show recent wake log only | No |
| `session-aligner logs daemon` | Show wake daemon log only | No |
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
window starts, next start, next wake, Claude Code path, power state, last ping,
last wake refresh, and upcoming wakes.

**When to use it:** Daily check that everything looks right.

**Example:**

```bash
session-aligner status
session-aligner status --raw    # append raw pmset -g sched output
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

Auto-wake makes your Mac wake ~2 minutes before each window start so pings can
fire even while the Mac is asleep (lid closed + plugged in).

### `session-aligner wake on`

**What it does:** Installs a root background helper (`com.sessionaligner.wake`)
that keeps one-time `pmset` wake events scheduled before each window start. Seeds
wakes immediately.

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

**What it does:** Removes the auto-wake helper, cancels scheduled wake events
created by Session Aligner, and cancels any old repeating wake.

**When to use it:** You no longer want the Mac to wake itself for window starts.

**Example:**

```bash
session-aligner wake off
```

**Notes:** Asks for your Mac password (admin access to remove the LaunchDaemon
and cancel `pmset` events).

---

### `session-aligner wake status`

**What it does:** Shows whether the auto-wake helper is installed and lists
upcoming wakes in human-readable form (`today at 14:58`, etc.).

**Example:**

```bash
session-aligner wake status
session-aligner wake status --raw    # append raw pmset -g sched output
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
- If auto-wake is installed, reloads the wake helper and refreshes upcoming wakes

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
| `aligner.launchd.log` | Output from the ping LaunchAgent |

---

## Uninstall

### `session-aligner uninstall`

**What it does:** Interactive uninstall:

1. Stops the ping schedule
2. Removes the auto-wake helper and cancels scheduled wakes
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

Auto-wake schedules wakes ~2 minutes before each (e.g. `04:58`, `09:58`,
`14:58`).

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
