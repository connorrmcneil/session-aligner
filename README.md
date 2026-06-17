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
2. Go to this folder and make the scripts runnable:

```bash
cd /Users/connormcneil/Projects/session-maxxing
chmod +x ping.sh aligner.sh
```

3. Test that it works (sends one ping right now):

```bash
./aligner.sh test
```

You should see a short reply from Claude and a `SUCCESS` line. If you see a
`FAILURE` line, it tells you what's wrong (for example "not logged in").

4. Turn on your schedule:

```bash
./aligner.sh setup
```

It will ask "every day or weekdays?" and ask for your times. Press Enter to
accept the default of **05:00 10:00 15:00 every day**.

5. Check it's scheduled:

```bash
./aligner.sh status
```

6. (Optional but recommended) Let the Mac wake itself so pings fire even while
   you're asleep:

```bash
./aligner.sh wake on
```

This asks for your Mac password once, installs a tiny background helper, and makes
the Mac wake ~2 minutes before **every** ping time. The helper keeps the upcoming
wakes scheduled automatically — you don't have to run it again. See "Will it run
while the Mac is asleep?" below.

---

## Everyday commands

| What you want | Command |
| --- | --- |
| Send a ping right now (test) | `./aligner.sh test` |
| Change the times | `./aligner.sh times "06:00 11:00 16:00"` |
| Turn the schedule OFF | `./aligner.sh off` |
| Turn the schedule back ON | `./aligner.sh on` |
| See schedule + recent activity | `./aligner.sh status` |
| Auto-wake the Mac before each ping | `./aligner.sh wake on` |
| Stop the auto-wake helper | `./aligner.sh wake off` |
| See the helper + upcoming wakes | `./aligner.sh wake status` |

Always run these from inside the folder
`/Users/connormcneil/Projects/session-maxxing` (do the `cd` line from setup
first).

## Example schedules

- **3 windows a day (default):** `05:00 10:00 15:00` — covers about 5am to 8pm.
- **Weekdays, two blocks:** run `./aligner.sh setup`, choose "weekdays", enter
  `09:00 14:00`.
- **Every 5 hours from 8am:** `./aligner.sh times "08:00 13:00 18:00 23:00"`.

## How do I know it's working?

Easiest proof - the log. Every ping now writes its real token usage to
`aligner.log`:

1. Run a ping: `./aligner.sh test`.
2. Look at the log: `./aligner.sh status` (or open `aligner.log`). You should see
   lines like:

```text
... SESSION: Resets 12:30pm | 18% used
... SUCCESS: interactive ping sent (5-hour window should now be open). TOKENS: input=10 output=168 cache_read=11856 | reply: "Hey! I'm ready to help..."
```

   An `output=` number greater than 0 means Claude actually answered - real tokens
   were spent through your subscription. That is your everyday "it's working"
   signal.

Authoritative check - the reset time. To confirm a ping actually *started* a new
window (only happens when no window is currently active):

1. Make sure no window is active (in Claude Code, `/usage` says "Starts when a
   message is sent").
2. Run `./aligner.sh test`, then run `/usage` again.
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

A sleeping Mac can't ping on its own, so `./aligner.sh wake on` installs a small
background helper that schedules a wake ~2 minutes before **every** ping time
(e.g. 04:58, 09:58, 14:58 for the default 05:00/10:00/15:00). macOS only allows one
*repeating* wake per day, so the helper keeps a few days of one-time wakes lined up
and refreshes them every hour (and whenever the Mac wakes). You set it up once and
forget it.

Whether a scheduled wake actually fires depends on power:

| State | Does the ping fire? |
| --- | --- |
| Lid open (asleep or awake) | Yes |
| Lid closed, **plugged into power** | Yes (Mac briefly wakes in the background) |
| Lid closed, **on battery** | No — macOS blocks scheduled wakes to save battery |
| Fully shut down | No |

So: **leave the Mac plugged in** and every ping will fire even with the lid closed.
If your Mac is closed and unplugged, the only fully reliable option is to run this
on an always-on machine logged into the same Claude account.

Check the helper and the upcoming wakes with `./aligner.sh wake status` (it lists
each scheduled wake). The helper logs each refresh to `wake.log` and
`wake.daemon.log` in the project folder.

### Why the wakes never run out (how it actually works)

When you run `./aligner.sh wake status` you'll only see the next **few days** of
wakes, not the whole future. That's intentional, and the schedule still continues
forever. Here's why:

- macOS only allows **one** *repeating* wake per day (via `pmset repeat`). That's
  not enough for 3 ping times, so instead we use **one-time** wake events and keep
  topping them up.
- `./aligner.sh wake on` installs a tiny background helper (a root LaunchDaemon
  called `com.sessionaligner.wake`) that re-runs `schedule-wakes.sh` **every hour**,
  **at startup**, and **whenever the Mac wakes**.
- Each time it runs, it makes sure the next ~3 days of wakes (2 minutes before each
  ping time) are scheduled, adding only the ones that are missing.
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
- **Pings don't fire on schedule (but `test` works):**
  - Make sure the agent is loaded: `./aligner.sh status` should say `Schedule: ON`.
  - If the time passed while the Mac was asleep/unplugged, see the table above,
    make sure `./aligner.sh wake on` is set up, and keep the Mac plugged in.
  - macOS may need permission: **System Settings > Privacy & Security > Full Disk
    Access** and add **Terminal**.
- **`test` says SUCCESS but `/usage` shows no session started:** the interactive
  automation didn't register. Check: are you logged into Claude Code with your
  Pro/Max account (`claude` then `/login`)? Is `expect` installed (`which expect`
  - on macOS it's `/usr/bin/expect`)? Note that headless API/`claude -p` pings
  (including `ping_api.py`) will never start the subscription window by design.
- **"expect not found":** install Xcode Command Line Tools (`xcode-select
  --install`); macOS normally ships `expect` at `/usr/bin/expect`.
- **Check the schedule by hand:** the schedule is a launchd agent named
  `com.sessionaligner.ping` (file at `~/Library/LaunchAgents/`). List it with
  `launchctl list | grep sessionaligner`. Don't edit the file by hand — use
  `./aligner.sh times` instead.

---

## Send-to-a-friend summary

> This tool makes Claude's 5-hour clock start when *you* want it to. Claude's
> session window begins at your first message and lasts 5 hours; this sends a
> tiny "hi" at set times (like 5am, 10am, 3pm) so a fresh window opens then.
> It does **not** give you more usage — it just lines the windows up with your
> day. To change times run `./aligner.sh times "07:00 12:00 17:00"`, to pause it
> run `./aligner.sh off`, and to check it run `./aligner.sh status`.

---

## Optional: API-billing version (advanced, usually NOT what you want)

If you ever want to ping using a **paid Anthropic API key** instead of your
Claude Code subscription, there's `ping_api.py`. Note this spends API credits
and lives in a **separate billing pool** — it does **not** touch your Claude
Code subscription's 5-hour window. Most people should ignore this and use the
default `./aligner.sh` flow above.

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
python3 ping_api.py
```
