# codex-use

A Claude Code skill that hands a task to OpenAI's Codex CLI (`codex exec`), checks that it really started, waits without blocking, and brings back a verified result.

## What it does

- Asks for model and reasoning effort once, validates both against Codex's own model cache, and writes a structured brief for Codex.
- Launches Codex detached, so the run survives the end of your Claude Code session. A start check proves a turn actually began before anyone says "it's running".
- Runs in a git worktree with no sandbox, so Codex is not stopped by false blockers (blocked `.git`, `/tmp`, network). A git-ref audit afterwards flags any branch or ref changes outside the run's own branch.
- Supports resume fix rounds on the same Codex thread, status checks (also from a later session), and a clean stop.

### Why not just run `codex exec`

A bare `codex exec` can hang on stdin, fail on a model id the CLI does not validate, and leaves "is it running?" unverified. This skill encodes those lessons in four scripts: prompt via stdin, model/effort validated and clamped, one `attempt-N/` directory per launch, pid-reuse-safe state, an exact final-report format, and a bounded review loop. See `references/lessons.md`.

## Requirements

- Claude Code
- Codex CLI, logged in (`codex login`). Tested on codex-cli 0.159.3; preflight reports flag drift on other versions.
- `jq`, `perl`, `git`, `bash` (3.2 compatible)
- macOS is tested. Linux is best-effort and not yet tested.

## Install

```
git clone https://github.com/guydotan55/codex-use ~/.claude/skills/codex-use
```

If you install elsewhere, adjust the `S=` path in `SKILL.md`.

## Usage

In a Claude Code session, on a non-main branch in a git worktree:

- `/codex-use` or "send this to codex": pick model and effort, Claude writes the brief and launches.
- "codex status" or "is codex done?": lists runs, including ones from earlier sessions.
- After a review, "have codex fix these": resumes the same thread as `attempt-2`.
- "stop codex": stops the attempt cleanly.

The scripts also work standalone (all have `--help`): `codex-preflight.sh`, `codex-launch.sh`, `codex-status.sh`, `codex-stop.sh`.

## How it works

Preflight checks the CLI, login and flags and reads available models. The launcher refuses `main`, `master` and a detached HEAD in build mode, snapshots git refs, writes a registry entry, and starts Codex in its own session and process group. State lives in `~/.codex-use/` (`runs/<run>/attempt-N/`, `runs.log`, `active.json`, `last.json`). Status reads Codex's event stream, commits since start, and Codex's own session record. Commits are the progress signal you can trust, so briefs ask for one commit per task.

## Safety

Build mode runs Codex with `--dangerously-bypass-approvals-and-sandbox`. Codex can run any command as you, use the network, and write anywhere your user can.

Guardrails:

- Build mode only starts in a git worktree on a non-main branch.
- Git refs in the main repository are snapshotted and audited afterwards; changes beyond the run's own branch are flagged as a breach.
- The brief tells Codex not to push, switch branches, or write outside the worktree and `/tmp`; `GIT_TERMINAL_PROMPT=0` is set.
- Read-only mode (`-s read-only`) exists for repo review. It cannot be resumed and has no network.

Not guarantees:

- The brief rules are instructions, not enforcement. Nothing stops Codex writing outside the worktree, reading secrets in your home directory, or touching other repos.
- Only git refs are audited, not the filesystem.
- Do not point it at untrusted repos or briefs: instructions hidden in repo content can steer a run that has no sandbox.
- `~/.codex-use/` stores briefs, event streams and logs, which may contain sensitive content.
- The skill reads undocumented Codex internals (`models_cache.json`, session records) and may break when Codex changes.

Use a disposable worktree and review the diff before pushing.

## License

MIT
