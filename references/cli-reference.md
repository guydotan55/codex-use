# Codex CLI reference (verified on codex-cli 0.159.3)

Everything here was checked against the installed CLI, not docs. When
`codex --version` changes, re-run `codex-preflight.sh`; a flag it reports
missing means this file and the scripts need updating.

## Prompt on stdin: one-time check

Run in a scratch git repo, detached with the same perl `setsid`
wrapper the launcher uses:

```
codex exec -m <model> -c model_reasoning_effort=low -s read-only --ephemeral --json - < prompt.txt
```

with `prompt.txt` = "Reply with the single word ok". Result:

- `stderr.log`: **empty** (0 bytes). No "Reading additional input from stdin" line, no banner.
- `events.jsonl`:
  ```
  {"type":"thread.started","thread_id":"<uuid>"}
  {"type":"turn.started"}
  {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
  {"type":"turn.completed","usage":{"input_tokens":18346,"cached_input_tokens":1408,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
  ```
- exit code 0.

**Winner: the `-` stdin form.** The launcher uses it for first runs and
resumes. The fallback (prompt as an argument plus `</dev/null`) is not used.
Further real test runs also passed with the stdin form.

## `codex exec` flags used by the launcher

From `codex exec --help` (anchored greps in `codex-preflight.sh`):

| Flag | Help text (abridged) | Used for |
|---|---|---|
| `-m, --model <MODEL>` | Model the agent should use | always |
| `-c, --config <key=value>` | Override a config value, value parsed as TOML, else literal | `-c model_reasoning_effort=<e>` |
| `-s, --sandbox <SANDBOX_MODE>` | read-only, workspace-write, danger-full-access | readonly mode: `-s read-only` |
| `--dangerously-bypass-approvals-and-sandbox` | Skip all confirmation prompts and execute without sandboxing | build mode |
| `--skip-git-repo-check` | Allow running Codex outside a Git repository | dir not a git repo; cache probe |
| `--ephemeral` | Run without persisting session files | cache probe and stdin check only |
| `-i, --image <FILE>...` | Image(s) attached to the initial prompt | `--image`. Takes several values, so the launcher always follows it with another flag |
| `--json` | Print events to stdout as JSONL | always |
| `-o, --output-last-message <FILE>` | File for the agent's last message | always; **not written on failure** |
| `[PROMPT]` | "If not provided as an argument (or if `-` is used), instructions are read from stdin" | `-` |

Not used: `-C/--cd` (resume lacks it; the wrapper does a real `cd`),
`--ignore-user-config` (would drop the user's trusted-project and plugin settings),
`-c approval_policy=never` (exec already runs with approval `never`; the session
record confirms it), `--worktree` (worktrees are created by you, not Codex).

## `codex exec resume` flags

`codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]`. Present: `-c`, `--last`,
`--all`, `--enable/--disable`, `-i, --image <FILE>`, `--strict-config`, `-m`,
`--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`,
`--worktree`, `--thread-source`, `--skip-git-repo-check`, `--ephemeral`,
`--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `-o`.
PROMPT: "If `-` is used, read from stdin".

**Absent: `-C/--cd` and `-s/--sandbox`.** Hence `cd` in the wrapper, and no
resume of read-only runs. The launcher passes exactly
`-m -c [bypass] [-i] [--skip-git-repo-check] --json -o <thread_id> -`.

Observed: a resumed run emits `thread.started` again with the **same**
thread id, and Codex's session record for it shows the requested model and
effort.

## Event stream (`--json` stdout)

Observed types, in order:

```
thread.started   {"type":"thread.started","thread_id":"<uuid>"}
turn.started     {"type":"turn.started"}
item.started     {"type":"item.started","item":{"id":"item_N","type":"command_execution","command":"/bin/zsh -lc '...'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
item.completed   same item with "exit_code":0 and "status":"completed" (or "failed")
item.completed   {"item":{"type":"file_change","changes":[{"path":"<abs>","kind":"add"}],"status":"completed"}}   (item.started first, status in_progress)
item.completed   {"item":{"type":"agent_message","text":"..."}}   (no item.started; the last one is the final report)
turn.completed   {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,"cache_write_input_tokens":N,"output_tokens":N,"reasoning_output_tokens":N}}
```

Item types seen in the tests: `command_execution`, `file_change`,
`agent_message`. Commands run through `/bin/zsh -lc`. No `reasoning` items
appeared at effort `low`. Failure shape: see the end of this file.

## No banner with `--json`

With `--json`, stderr stayed empty in all runs: there is no startup banner
with a model line. The model Codex actually used is read from its own session
record instead: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread_id>.jsonl`,
last line of `"type":"turn_context"`, fields `payload.model`,
`payload.collaboration_mode.settings.reasoning_effort`,
`payload.sandbox_policy.type`, `payload.approval_policy`. `codex-status.sh`
prints these as the "codex says" line. `--ephemeral` runs have no session record.

## Process tree

`ps -o pid,ppid,pgid,command -g <pid>` right after launch:

```
<pid>   1      <pid>  bash .../attempt-1/wrapper.sh
<pid+5> <pid>  <pid>  node /usr/local/bin/codex exec -m <model> ... -
<pid+6> <pid+5> <pid> .../@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex exec -m <model> ... -
```

The wrapper is a session and group leader (pgid == pid) with parent 1, so a
group kill reaches node and the native binary and nothing else.
`meta.json.live_command` is the node line.

## Model cache `~/.codex/models_cache.json`

Top level: `client_version` (equals the CLI version that wrote it, "0.159.3"),
`fetched_at`, `etag`, `identity`, `models[]`. Per model: `slug`,
`display_name`, `visibility` ("list" or "hide"), `priority` (lower first),
`default_reasoning_level`, `supported_reasoning_levels[] {effort, description}`,
and many more. Example shape (the list changes by CLI version and account; the skill always reads the live file):

| slug | default | max | visibility |
|---|---|---|---|
| `<model-a>` | medium | xhigh | list |
| `<model-b>` | low | ultra | list |
| `<internal-model>` | medium | max | hide |

Effort order used for clamping: minimal < low < medium < high < xhigh < max < ultra.

## Failure shape (invalid model, test 4)

```
{"type":"thread.started","thread_id":"<uuid>"}
{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `<bad-model>` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}
{"type":"turn.started"}
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The '<bad-model>' model is not supported when using Codex with a ChatGPT account.\"}}"}
{"type":"turn.failed","error":{"message":"<same JSON string as above>"}}
```

Exit code 1, `-o` file not written, stderr empty, about 3 s. The CLI does not
validate the model id before the API call, and an `item.completed` of type
`error` can be a non-fatal warning that arrives before `turn.started`. Its
`error.message` is itself a JSON string; show it verbatim.

## Login

`codex login status` prints `Logged in using ChatGPT` when logged in.
