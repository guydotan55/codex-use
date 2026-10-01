---
name: codex-use
description: Launch and drive OpenAI Codex CLI from inside a Claude Code session for builds, fixes, repo reviews or research, with no approval or sandbox barriers, after asking which model and reasoning effort to use. Use whenever the user says codex, 'send to codex', 'build with codex', 'codex review', '/codex-use', or when an orchestrating workflow picks Codex as the worker for a big build. Also use for follow-up fix rounds on a finished Codex run and for 'is codex done?' / 'codex status' questions, including runs started in an earlier session.
---

# codex-use

Hand a task to Codex CLI (`codex exec`), verify it really started, wait without
blocking, and bring back a verified result. The user answers one dialog (model and
effort); everything else is derived or encoded in four scripts.

The scripts exist so the flags are never re-derived by hand. Each one encodes a
past failure: a nine-hour hang on stdin, sandbox walls that made Codex report
false blockers, an unchecked "building now", a model rejected mid-run. Use the
scripts, not a hand-written `codex exec` line. The story behind each choice is in
`references/lessons.md`; verified flags and event shapes are in
`references/cli-reference.md`.

Scripts (all have `--help`):

```
S=~/.claude/skills/codex-use/scripts   # adjust if you installed the skill elsewhere
$S/codex-preflight.sh                 # version, login, flag drift, models+efforts -> JSON
$S/codex-launch.sh ...                # builds + detaches a run or a resume, returns at once
$S/codex-status.sh <attempt>          # also --started, --terminal, --audit, --list, --finish
$S/codex-stop.sh <attempt>            # clean stop of one attempt
```

State is machine-local in `~/.codex-use/` (`runs/<run>/attempt-N/`, `runs.log`,
`active.json`, `last.json`). It is deliberately outside `~/.claude`, so config sync tools do not copy it
to other machines.

Does not cover: Claude subagent dispatch, reading old
Codex transcripts, or editing `~/.codex/config.toml` (never change it; every
setting is passed per run).

## Step 0. Entry conditions

- **Which mode.** Build mode (no sandbox) for building, fixing and research.
  Read-only mode only for "review / summarize / explain this repo": its sandbox
  also blocks the network, so research there fails silently. Research runs in
  build mode with "write nothing" in the brief's DON'T list.
- **Where.** Build mode runs inside a git worktree on a non-main branch, because
  the worktree, commit-per-task and the ref audit are the guardrails that make
  running without a sandbox acceptable. If the session is on `main`, create a worktree
  on a new branch first (`git worktree add ../<name> -b <name>`); the new
  worktree becomes `--dir`. The launcher
  refuses `main`, `master` and a detached HEAD in build mode.
- **One run per directory.** Run `$S/codex-status.sh --list`. If a run already
  targets this dir, tell the user and finish or stop that one first; the launcher
  refuses a second run there anyway.

## Step 1. Preflight

```
$S/codex-preflight.sh
```

It prints one JSON object and exits non-zero with `PREFLIGHT FAIL: <reason>` on
a hard failure. Relay the reason as is. The two common ones:

- **Not logged in.** Tell the user to run `codex login` in their own terminal (it is
  interactive). A file in `~/.codex` is not proof of a login; the script asks
  the CLI.
- **Flag missing.** The CLI changed. Stop and say which flag; the scripts need
  updating before any launch.

From the JSON keep `models` (slug, default_effort, max_effort, visibility),
`last` and `recent_models`. A `warnings` entry about a stale cache means the
model list may be old; say so in the dialog.

## Step 2. Ask model and effort (one dialog)

One `AskUserQuestion` call with two questions, nothing else (if that tool is not available, ask both in one plain-text message). Sandbox mode is
derived (Step 0), the directory is the current worktree, and you write the brief.

- **Model** — four options:
  1. `last.model` labelled "(last used)",
  2. to 4. the next most recent from `recent_models`, then cache order
     (`visibility == "list"`, by priority) to fill up.
  Each option's description: "default <default_effort>, max <max_effort>". The
  tool's built-in Other takes any id. Validate the answer against `models[].slug`;
  for an unknown id re-ask once, listing the valid listed ids.
- **Effort** — `low`, `medium`, `high`, `xhigh` (every cached model supports
  these), Other for `max` or `ultra`. Do not re-ask when the effort exceeds the
  model's maximum: the launcher clamps it and prints `CLAMPED: ...`, and you
  mention that in the running line.

**Headless contract.** When no one can answer (a worker, a test, a scheduled
job), model and effort must come in the instructions you were given. The
launcher refuses to run without both; there is no silent default, because the
CLI default model has been rejected mid-run before.

## Step 3. Write the brief

Copy the template from `references/brief-template.md` into a file (the
session scratchpad is fine) and fill every field: GOAL, WHY, CONTEXT with
absolute paths, DO with one commit per task, DON'T, DONE WHEN, REPORT, then the
ENVIRONMENT and FINAL REPORT blocks unchanged except for `<dir>` and `<branch>`.
The template has variants for read-only, research and fix rounds. Codex cannot
see this conversation, so whatever it needs must be in the brief.

## Step 4. Launch

```
$S/codex-launch.sh --dir <abs worktree> --model <id> --effort <level> \
  --mode build|readonly --brief <file> [--slug <short-name>] [--image <file>]...
```

It validates the model, clamps the effort, snapshots refs and `start_sha`,
writes the registry, detaches Codex into its own session and returns within
about three seconds with `RUN_DIR=`, `ATTEMPT_DIR=`, `PID=`, `MODEL=`, `EFFORT=`
(and `CLAMPED:` if it clamped). Keep `RUN_DIR` and `ATTEMPT_DIR`; every later
step uses them. The exact command is in `<attempt>/command.txt` and the live
process's command line in `meta.json` (`live_command`).

## Step 5. Verify the launch (always)

Never say "Codex is running" before this step proves it. Arm a Monitor that
ends when Codex starts a turn, fails, or exits, capped at 90 s (write the
literal scripts path instead of `$S`, since the Monitor shell does not have it;
without a Monitor tool, poll the same command in a short loop):

```
Monitor  description: "codex start <slug>"   timeout_ms: 120000
command: end=$((SECONDS+90)); until $S/codex-status.sh --started '<attempt>'; do [ $SECONDS -ge $end ] && { echo "NO TURN AFTER 90s"; exit 1; }; sleep 2; done
```

Then run `$S/codex-status.sh <attempt>` once and report only what it shows:

- **state running, no errors** → "Codex is running: <codex says line>, thread
  <id>, run dir <RUN_DIR>." The "codex says" line is Codex's own record of model,
  effort and sandbox, not what was requested; if they differ, say so. Mention a
  clamp here.
- **errors (verbatim) or finished-failed** → show the error text exactly, plus
  the two known fixes: a rejected model id means pick another model, or update
  the CLI and re-login; an auth error means `codex login`. Offer to go back to
  Step 2. Do not silently retry with another model.
- **NO TURN AFTER 90s** → suspected hang. Show the stderr tail the status prints
  and offer `codex-stop.sh`.

## Step 6. Wait

Arm a Monitor on the terminal check. It costs nothing while Codex works:

```
Monitor  description: "codex done <slug>"   timeout_ms: 1800000
command: until $S/codex-status.sh --terminal '<attempt>'; do sleep 15; done
```

On expiry, re-arm the same Monitor. Use no foreground `sleep`. `--terminal`
fires on `turn.completed`, `turn.failed`, an `exit_code` file, or the process
gone (checked with its recorded start time so a reused pid is not mistaken for
the run).

If the user asks "status?" mid-run, run `$S/codex-status.sh <attempt>`: elapsed,
last event, items done, commits since start, dirty files. Commits are the
trustworthy progress signal; the event stream is the second.

The run is detached and survives the end of this session. In a later session,
"codex status" starts with `$S/codex-status.sh --list`, which shows every
unreported run as running, finished-unreported or died; pick up at Step 7.

## Step 7. Finish

Keep this bounded: one diff read, one command beyond the checklist.

1. Read `<attempt>/last-message.md`. A missing file, a non-zero `exit_code`, or
   no `turn.completed` is a failure, whatever the message says. If the four
   FINAL REPORT headings are missing (for example Codex ended on a question),
   show the raw message and call it "no structured report".
2. In the worktree: `git log --oneline <start_sha>..HEAD` and
   `git diff --stat <start_sha>` (`start_sha` is in `run.json`). For a fix
   round, use the attempt's own `head_at_start` from its `meta.json` instead.
3. Git-ref audit: `$S/codex-status.sh --audit <run>`. It compares every ref in
   the main repository with the snapshot taken at launch. Any change other than
   the run's own branch is printed as `**BREACH**`; put it in bold at the top of
   the report. Another session working in the same repo also moves refs, so name
   the ref and let the user judge.
4. `$S/codex-status.sh --finish <attempt>` writes the END line (exit, duration,
   tokens) and removes the run from `active.json`. It prints the outcome and
   whether the report is structured.
5. Report to the user: Done / Not done / Assumptions from Codex's report, commits,
   files changed, duration, tokens, audit result. Flag every "Not done" item.

## Step 8. Review and one fix round

1. Optional but recommended: run one independent review of the worktree diff
   (for example `/code-review`, or a reviewer subagent) and announce it first.
2. If findings are worth fixing, write a fix brief (the fix-round variant in
   the template: findings with file and line, same ENVIRONMENT block) and launch
   a resume:
   ```
   $S/codex-launch.sh --resume <RUN_DIR> --model <id> --effort <level> --brief <fix-brief>
   ```
   Codex continues the same thread, so it still has the code in context. It
   creates `attempt-2/`; repeat Steps 5 to 7 on that attempt. Read-only runs
   cannot be resumed (`codex exec resume` has no sandbox flag).
3. Verify the fix yourself with one diff read and one test command.
4. A second fix round is never automatic. Ask the user, naming what is still open,
   because unbounded review-fix loops are where Codex runs spiral.

## Step 9. Hand-off

Branch name, commits, how to verify, open items. Pushing and the PR are done by you when the user says so.
Codex never pushes.

## Stop

```
$S/codex-stop.sh <attempt>
$S/codex-status.sh --finish <attempt>
```

The stop script checks that the recorded pid is alive with its recorded start
time and that it leads its own process group (so the kill cannot reach this
Claude shell), sends TERM to the group, waits 10 s, then KILL, writes
`exit_code` 143, and prints the last commit and `git status --short`. Work after
Codex's last commit is lost, which is why the brief asks for a commit per task.

Changing model mid-run is not possible. Stop at a commit boundary, then
`--resume` with the new `--model`. Whether the thread really switches is read
from the "codex says" line in Step 5; report what it shows.
