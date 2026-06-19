# Session Aligner (macOS)

Claude's 5-hour session window starts the moment you send your first message and
resets exactly 5 hours later. This little tool sends one tiny "ping" to Claude
Code at times you choose (for example 5:00, 10:00, and 3:00), so a fresh 5-hour
window begins right when you want to start working. That's it.

**Important:** This does NOT give you more usage. It does not increase or extend
the 5-hour limit or your weekly cap. It only controls *when* a 5-hour window
starts, so the windows line up with your day instead of starting at random times.

It uses your normal Claude Code login (the same account you already use). No API
key and no programming required. The schedule runs through macOS `launchd`, which
survives reboots and can run a missed ping when your Mac wakes from sleep.

## TL;DR

Session Aligner starts Claude's 5-hour window at the times you choose.

Recommended default:

```
05:00 10:00 15:00
```

These are **START** times. For example, `05:00` starts a Claude window around
05:00. It does **not** increase your usage limits or give extra usage - it only
lines up your existing Claude window with your day.

Install (creates a global `session-aligner` command):

```bash
./install.sh
```

After install, run it from anywhere:

```bash
session-aligner status
session-aligner test
session-aligner times "05:00 10:00 15:00"
```

Optional auto-wake (so pings fire even while the Mac sleeps):

```bash
session-aligner wake on
```

Auto-wake asks for your Mac password **once** because macOS requires admin/root
access to schedule system wake events (via `pmset`). Your password is handled by
macOS `sudo` and is **not** stored by Session Aligner. The normal ping schedule
runs as you and needs no admin access.

Didn't run `./install.sh`? Everything also works from this folder with
`./aligner.sh` instead of `session-aligner` (for example `./aligner.sh status`).

## How it actually works (read this once)

A few things that are surprising at first but important to understand:

- **The 5-hour window belongs to your ACCOUNT, not to a folder or project.** It is
  shared across every Claude Code project, claude.ai, and Claude Desktop. There is
  only one window at a time. Starting it from this tool's folder starts it
  everywhere.
- **Each ping is its own separate, short-lived Claude Code session.** The ping
  opens a brand-new session, types "hi", waits for the reply, and closes - all in
  about 20 seconds, invisibly in the background. That single "hi" is the "first
  message" that starts a fresh 5-hour window at the time you chose.
- **That's why `/usage` in your own session doesn't seem to "move".** The numbers
  at the top of `/usage` describe the session you are currently sitting in. The
  ping ran in a different session that has already closed, so opening a fresh one
  to check shows nothing for it. The window and limits it affected are still
  account-wide, though - they just aren't shown per-session.
- **The ping is intentionally tiny**, so the percentage bars in `/usage` barely
  budge. Do not judge it by the percentages. The real proof is: (a) the
  **`TOKENS:` line written to `aligner.log` on every ping** (showing real input/
  output tokens were used), and (b) the **"Current session - Resets at H:MM"**
  time, which jumps ~5 hours ahead when a ping starts a fresh window.

> **Honest caveat.** On June 15, 2026 Anthropic changed billing so that *headless*
> `claude -p` calls no longer start your Pro/Max 5-hour window (they bill a
> separate metered pool). Only an *interactive* Claude Code session starts that
> window. So this tool drives the real interactive app through a pseudo-terminal
> (`expect`) and types "hi". This is the best available way to start the window on
> a schedule, but it is automating the interactive app: it may be against the
> spirit of that billing change and Anthropic could stop it working at any time.
> Always confirm it is working using the log/`/usage` checks below.

---

## What you need first

- Claude Code installed and logged in. Open a terminal, type `claude`, and if it
  asks you to sign in, run `/login` once. After that you're set.

## One-time setup (copy/paste)

1. Open the Terminal app.
2. Go to this folder and run the installer:

```bash
cd /Users/connormcneil/Projects/session-aligner
./install.sh
```

The installer makes the scripts runnable, checks requirements (Claude Code,
`expect`), and creates a global `session-aligner` command so you can run it from
anywhere. It then offers to run guided setup for you.

> Creating the global command may ask for your Mac password once (because
> `/usr/local/bin` is owned by the system). If you skip or it can't be created,
> everything still works from this folder using `./aligner.sh` instead.

3. Run guided setup (the installer offers this, or run it yourself):

```bash
session-aligner setup
```

It asks whether to use the recommended **05:00 10:00 15:00** window starts, every
day or weekdays, and whether to enable auto-wake. Press Enter to accept the
recommended answers.

4. Check it's scheduled:

```bash
session-aligner status
```

5. Send a test ping right now (optional):

```bash
session-aligner test
```

You should see a short reply from Claude and a `FRESH WINDOW STARTED` line (if no
window was active). Other honest outcomes are `USED EXISTING WINDOW` (a window was
already running) and `OLD WINDOW ACTIVE` (the old window is about to reset — the tool
then waits and retries once). A `FAILURE` line tells you what's wrong (for example
"not logged in"). You can also run `session-aligner doctor` any time to diagnose
problems. See [Retry after an active old window](docs/commands.md#retry-after-an-active-old-window).

### About auto-wake and your Mac password

Auto-wake (`session-aligner wake on`) makes the Mac wake **15 minutes before** every
window start so pings fire even while you're asleep. It installs a tiny background
helper that keeps the upcoming wakes scheduled automatically — you don't have to
run it again.

It asks for your Mac password once because **macOS requires admin/root access to
schedule system wake events** through `pmset`. Your password is handled by macOS
`sudo` and is **not** stored by Session Aligner, and the helper never touches your
Claude account. The normal ping schedule runs as you and needs no admin access.
See "Will it run while the Mac is asleep?" below.

> **Note:** auto-wake installs a **root LaunchDaemon** (`com.sessionaligner.wake`)
> at `/Library/LaunchDaemons/`. For personal/single-user use it runs the scheduler
> (`schedule-wakes.sh`) straight from **this repo folder** — the daemon points at the
> script where it lives, so don't move or delete the folder while auto-wake is on
> (if you do, run `session-aligner wake off`, relocate, then `wake on` again).

### Wake time vs. ping time (why the Mac wakes early)

There are two different moments, and keeping them apart is the whole point:

- **Ping time** *is* the Claude window start (`05:00`, `10:00`, `15:00`). The ping is
  what opens the 5-hour window, so it must land at the exact start time — it is never
  moved earlier.
- **Wake time** is **15 minutes earlier** (`04:45`, `09:45`, `14:45`). Waking early
  gives macOS time to come *fully* awake — a freshly-woken Mac is sluggish, and a
  2-minute lead used to leave pings firing 10–15 minutes late.

To stop the Mac from dozing off again between the early wake and the ping, auto-wake
also installs a small **preflight keep-awake** agent (`com.sessionaligner.preflight`,
runs as you, no admin needed). At each wake time it runs macOS `caffeinate` for
20 minutes, holding the Mac awake from `04:45` until ~`05:05` — straight through the
`05:00` ping. Timeline: **04:45** wake + caffeinate → **05:00** ping fires on time →
**05:05** caffeinate expires and the Mac may sleep again.

Both numbers are configurable:

```bash
session-aligner wake lead 15        # wake this many minutes early (1-60, default 15)
session-aligner wake keep-awake 20  # caffeinate duration in minutes (5-90, default 20)
session-aligner wake status         # shows window starts, wake lead, keep-awake, wake/ping times
```

Keep-awake must outlast the wake lead (so caffeinate spans past the ping); if you set
it too low it is automatically raised to `lead + 5`.

You should **not** need to change any macOS sleep settings for the default setup —
auto-wake handles waking and staying awake on its own. Just keep the Mac **plugged in**
for reliable wakes with the lid closed (see the power table below).

---

## Everyday commands

| What you want | Command |
| --- | --- |
| Send a test ping right now | `session-aligner test` |
| Change the window start times | `session-aligner times "06:00 11:00 16:00"` |
| Turn the schedule OFF | `session-aligner stop` |
| Turn the schedule back ON | `session-aligner start` |
| See a friendly status overview | `session-aligner status` |
| See the next window start + wake | `session-aligner next` |
| Diagnose problems | `session-aligner doctor` |
| Fix common problems | `session-aligner repair` |
| Show recent activity / logs | `session-aligner logs` |
| Auto-wake before each window start | `session-aligner wake on` |
| Stop the auto-wake helper | `session-aligner wake off` |
| See the helper + upcoming wakes | `session-aligner wake status` |
| Change how early the Mac wakes | `session-aligner wake lead 15` |
| Change the keep-awake duration | `session-aligner wake keep-awake 20` |
| Remove everything | `session-aligner uninstall` |

If you didn't run `./install.sh`, use `./aligner.sh` instead of `session-aligner`
(for example `./aligner.sh status`), run from inside the folder
`/Users/connormcneil/Projects/session-aligner`. `start`/`stop` are the same as the
older `on`/`off`, which still work too.

## Example schedules

Recommended window starts:

```
05:00 10:00 15:00
```

These are **START** times. With the default schedule:

- `05:00` starts the early window
- `10:00` starts the late morning window
- `15:00` starts the afternoon window

Together they cover roughly 5am to 8pm. This does not give you more usage — it only
aligns the existing windows with your day.

Other examples:

- **Weekdays, two blocks:** run `session-aligner setup`, choose "weekdays", enter
  `09:00 14:00`.
- **Every 5 hours from 8am:** `session-aligner times "08:00 13:00 18:00 23:00"`.

## How do I know it's working?

Easiest proof - the log. Every ping now writes its real token usage to
`aligner.log`:

1. Run a ping: `session-aligner test`.
2. Look at the log: `session-aligner logs` (or open `aligner.log`). You should see
   lines like:

```text
... SESSION: Resets 8:11pm | 0% used
... FRESH WINDOW STARTED: resets at 8:11pm (in 300m). TOKENS: input=10 output=168 cache_read=11856 | reply: "Hey! I'm ready to help..."
```

   An `output=` number greater than 0 means Claude actually answered - real tokens
   were spent through your subscription. The `FRESH WINDOW STARTED` line (reset ~5h
   out) is the proof a *new* window opened. If you instead see `USED EXISTING WINDOW`
   or `OLD WINDOW ACTIVE`, a window was already running — that's reported honestly
   rather than as a fresh-window success. See
   [Retry after an active old window](docs/commands.md#retry-after-an-active-old-window).

Authoritative check - the reset time. To confirm a ping actually *started* a new
window (only happens when no window is currently active):

1. Make sure no window is active (in Claude Code, `/usage` says "Starts when a
   message is sent").
2. Run `session-aligner test`, then run `/usage` again.
3. **Current session** should now show an active window that **resets ~5 hours
   from now**. That before -> after flip is the definitive proof.

(Remember: don't expect the percentage bars to jump - the ping is tiny. Judge it
by the `TOKENS:` line and the reset time, not the percentages.)

## How many pings should I use?

Three per day is plenty. Each ping is only a couple of tokens, so it costs
almost nothing — but adding lots of pings just wastes a few messages and makes
your overlapping 5-hour windows confusing. Stick to the few start times that
match your real day.

## Will it run while the Mac is asleep?

A sleeping Mac can't ping on its own, so `session-aligner wake on` installs a small
background helper that schedules a wake **15 minutes before** every window start
(e.g. 04:45, 09:45, 14:45 for the default 05:00/10:00/15:00) and a preflight
`caffeinate` that holds the Mac awake from the wake until just past the ping. macOS
only allows one *repeating* wake per day, so the helper keeps a few days of one-time
wakes lined up and refreshes them at load/startup and hourly (and usually soon after
the Mac wakes, when a missed hourly run catches up). You set it up once and forget it.
The wake is deliberately early — see [Wake time vs. ping time](#wake-time-vs-ping-time-why-the-mac-wakes-early)
for why pings used to land 10–15 minutes late with a shorter lead.

This is also the only part of the tool that needs your Mac password: scheduling
system wake events requires admin/root access through `pmset`. The password is
handled by macOS `sudo`, is never stored, and the helper does not use your Claude
account.

Whether a scheduled wake actually fires depends on power:

| State | Does the ping fire? |
| --- | --- |
| Lid open (asleep or awake) | Yes |
| Lid closed, **plugged into power** | Yes (Mac briefly wakes in the background) |
| Lid closed, **on battery** | No — macOS blocks scheduled wakes to save battery |
| Fully shut down | No |

So: **leave the Mac plugged in** and every window start will fire even with the lid
closed. If your Mac is closed and unplugged, the only fully reliable option is to
run this on an always-on machine logged into the same Claude account.

Check the helper and the upcoming wakes with `session-aligner wake status` (it
lists each scheduled wake). The helper logs each refresh to `wake.log` and
`wake.daemon.log` in the project folder.

### Why the wakes never run out (how it actually works)

When you run `session-aligner wake status` you'll only see the next **few days** of
wakes, not the whole future. That's intentional, and the schedule still continues
forever. Here's why:

- macOS only allows **one** *repeating* wake per day (via `pmset repeat`). That's
  not enough for 3 window starts, so instead we use **one-time** wake events and
  keep topping them up.
- `session-aligner wake on` installs a tiny background helper (a root LaunchDaemon
  called `com.sessionaligner.wake`) that re-runs `schedule-wakes.sh` **at load/startup**
  and **every hour**, and **usually soon after the Mac wakes** (a missed hourly run
  catches up shortly after wake — it is not an explicit wake trigger).
- Each time it runs, it makes sure the next ~3 days of wakes (`WAKE_LEAD_MIN` minutes
  before each window start — 15 by default) are scheduled, adding only the ones that
  are missing.
- One-time wakes disappear automatically after they fire, so the list stays short
  and is constantly pushed forward — today's run schedules out to day 3, tomorrow's
  run adds day 4, and so on, with no end.

So the 3-day window you see is just a rolling safety buffer. Even if the Mac sleeps
for a couple of days, the soonest scheduled wake fires, the Mac wakes, the helper
runs again, and it refills the buffer. As long as the helper is installed (and the
Mac is plugged in for the wakes to fire), you never reach the end of the list.

You may notice the same time listed **twice** in `wake status`. That's harmless —
two wake events at the identical moment just wake the Mac once, and they expire on
their own after firing. It does not cause double-pings (pinging is driven by a
separate agent, `com.sessionaligner.ping`).

## Troubleshooting

- **"claude command not found":** Install Claude Code and run it once so you're
  logged in, then try again.
- **"not logged in":** In Terminal run `claude`, then `/login`.
- **Quickest check:** run `session-aligner doctor` — it lists what's wrong and the
  exact commands to fix it.
- **Pings don't fire on schedule (but `test` works):**
  - Make sure the agent is loaded: `session-aligner status` should say `Schedule: ON`.
  - If the time passed while the Mac was asleep/unplugged, see the table above,
    make sure `session-aligner wake on` is set up, and keep the Mac plugged in.
  - macOS may need permission: **System Settings > Privacy & Security > Full Disk
    Access** and add **Terminal**.
- **A ping replied but didn't start a fresh window:** the tool now reports this
  honestly instead of calling it `SUCCESS`. `USED EXISTING WINDOW` / `OLD WINDOW
  ACTIVE` mean a window was already running. For an `OLD WINDOW ACTIVE` (about to
  reset) the tool waits past the reset and retries once automatically; tune this with
  `session-aligner retry grace`/`after-reset`, or turn it off with
  `session-aligner retry off`.
- **A ping logs `PING SENT (UNCONFIRMED)`:** Claude replied, but the `/usage` reset
  time couldn't be read, so the tool can't confirm whether the window is fresh. Open
  Claude Code and check `/usage` manually. Are you logged into your Pro/Max account
  (`claude` then `/login`)? Is `expect` installed (`which expect` — on macOS it's
  `/usr/bin/expect`)? The ping uses **interactive** Claude Code driven through a
  pseudo-terminal (`expect`); headless `claude -p` pings will never start the
  subscription window by design.
- **"expect not found":** install Xcode Command Line Tools (`xcode-select
  --install`); macOS normally ships `expect` at `/usr/bin/expect`.
- **Check the schedule by hand:** the schedule is a launchd agent named
  `com.sessionaligner.ping` (file at `~/Library/LaunchAgents/`). List it with
  `launchctl list | grep sessionaligner`. Don't edit the file by hand — use
  `session-aligner times` instead.

---

## Send-to-a-friend summary

> This tool makes Claude's 5-hour clock start when *you* want it to. Claude's
> session window begins at your first message and lasts 5 hours; this sends a
> tiny "hi" at set times (like 5am, 10am, 3pm) so a fresh window opens then.
> It does **not** give you more usage — it just lines the windows up with your
> day. Install it with `./install.sh`, then to change times run
> `session-aligner times "07:00 12:00 17:00"`, to pause it run `session-aligner
> stop`, and to check it run `session-aligner status`.
