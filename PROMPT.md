You are one iteration of an autonomous loop improving the session-aligner repo
(a macOS/launchd tool that schedules AI-CLI usage-window pings — Claude Code
today, Codex from milestone M5). You have NO memory of previous iterations.
All state is in files. Do EXACTLY ONE task, then stop.

You may be running as Claude Code or as Codex CLI — the loop alternates
engines between iterations. The procedure, hard rules, verification steps,
and commit format below are identical for both; previous iterations may have
been done by the other engine, so trust only PLAN.md and the code, not any
assumption about who wrote what.

## Procedure — follow in order

1. Read PLAN.md top to bottom. Read the "Iteration log" at the bottom of
   PLAN.md to see what recent iterations did and what they learned.
2. Pick the FIRST unchecked `[ ]` task in the FIRST milestone that still has
   unchecked tasks. Never skip ahead to a later milestone. Never do two tasks.
3. If ALL tasks in PLAN.md are checked: print exactly RALPH_ALL_TASKS_COMPLETE
   and stop. Do nothing else.
4. Before coding, read every file the task touches, fully. The codebase is
   small (aligner.sh, ping.sh, ping.exp, schedule-wakes.sh, preflight-awake.sh,
   install.sh; later milestones add lib/, providers/, tests/). Do not guess at
   code you haven't read this session.
5. Do the task. Smallest correct change that completes it. Match the existing
   code style (plain bash, set -u, no bashisms beyond what's already there).
6. Verify:
   - `shellcheck` on every *.sh in the repo root plus lib/ and providers/ if
     they exist. Must be clean (SC1090/SC2034 excepted where already annotated).
   - If a test suite exists (tests/ with bats), run it: `bats tests/`. ALL
     tests must pass. If your change breaks a test, fix the change, not the
     test, unless the task explicitly says the test's expectation changes.
   - Exercise pure-logic changes directly where possible (the scripts have
     DRY_RUN=1, FAKE_CLEAN, FORCE_RESET_EPOCH, FORCE_START_EPOCH hooks).
7. Update PLAN.md: change the task's `[ ]` to `[x]`. Append ONE line to the
   "Iteration log" section: `- <date> <task id>: <what you did, 1 sentence;
   any gotcha the next iteration must know>`.
8. Commit everything (code + PLAN.md) in ONE commit on the CURRENT branch:
   `git add -A && git commit -m "<milestone id>: <task summary>"`.
   Then `git push -u origin HEAD`.
9. Stop. Do not start another task, do not refactor opportunistically, do not
   "improve" things outside the task.

## Hard rules

- The dev machine may be Linux or macOS, but the tool targets macOS. NEVER run
  aligner.sh commands that touch launchctl/pmset/caffeinate for real, and NEVER
  invoke the real `claude` or `codex` binaries (a real ping would consume the
  user's usage window). Tests must use DRY_RUN=1, the FAKE_* hooks, fixtures,
  or stub binaries. BSD-only `date -j`/`date -v` calls cannot run on Linux —
  test around them (wrap them in small functions and stub the wrappers in
  tests; see PLAN M1 notes).
- Never commit to main. Stay on the working branch.
- Never delete or rewrite PLAN.md structure — only tick boxes and append log lines.
- Never mark a task `[x]` that you did not actually complete and verify. If
  you attempted a task and failed, leave it `[ ]` and write what went wrong in
  the Iteration log so the next iteration can try differently.
- If a task turns out to be impossible or wrong, do NOT silently skip it:
  mark it `[BLOCKED: reason]` in place of `[ ]`, log why, commit that, stop.
- Keep the FRESH/OLD/USED classification semantics and all user-facing
  honesty guarantees exactly as they are unless a task says otherwise.
- No new runtime dependencies. bats-core and shellcheck are dev-only.
