# Design notes: lessons encoded in this skill

Why the scripts look the way they do. If you are tempted to "simplify" a
script, check this list first.

## From real runs

| # | What happened | Where it is handled |
|---|---|---|
| 1 | Run hung 9 h on "Reading additional input from stdin..." | Prompt via `-` on stdin (or `</dev/null` fallback), in the launcher, always |
| 2 | Nobody checked the launch; "building now" was said unverified | Step 5, mandatory Monitor-based check keyed on `turn.started` |
| 3 | `workspace-write` blocked the worktree `.git`, `/tmp`, Postgres shm, network; Codex reported false blockers and stopped | Bypass flag in build mode; ENVIRONMENT block says "continue past obstacles" |
| 4 | The CLI default model was not the one wanted, and a model can't change mid-run | Step 2 asks and validates every time; `-m` always passed; stop/resume path documented; banner model reported |
| 5 | A newer model was rejected until the CLI was updated and re-logged-in; the plan was wrongly blamed | Preflight uses `codex login status` and version-keyed cache staleness; failure text shown verbatim with the two known fixes |
| 6 | Progress invisible except via commits; `.output` was noise | `--json` events + commits in `codex-status.sh` |
| 7 | A "use Claude skills" line in a brief confused Codex | ENVIRONMENT block says no Claude skills exist here |
| 8 | `codex models` fails without a TTY | Models read from `models_cache.json` |
| 9 | `-o` not written on failure | Step 7 treats missing file as failure |
| 10 | Effort never set, so unknown | Effort asked, clamped, passed and logged every run |

## From design review

| Finding | Handled by |
|---|---|
| `resume` has no `-C` / `-s` | `cd` instead of `-C`; separate resume flag subset; no resume of read-only runs |
| Resume would overwrite the old attempt's files and trip the monitor | One `attempt-N/` directory per launch |
| No `setsid` on macOS; group kill could hit the Claude shell | perl `POSIX::setsid` detach; pgid == pid check before kill |
| `exit_code` could be missing or half-written; pid reuse | Atomic tmp + mv; pid + start time recorded and checked |
| `"$(cat brief)"` quoting, leading `-`, `ps` exposure | Prompt via `-` on stdin, with a one-time check and a fallback |
| Orphaned runs when the Claude session ends | Launcher-written START line, `active.json`, `--list` |
| 45 s wait unspecified; `thread.started` too early | Monitor until-loop keyed on `turn.started`, 90 s cap |
| Eight models vs four options; effort not validated | Last-used plus three recent; validation with one re-ask; effort clamp |
| Flag grep too loose and blind to resume | Anchored patterns, both help texts, framed as a drift alarm |
| Probe would fail outside a git repo; age-based staleness | `--skip-git-repo-check`; `client_version` comparison |
| `auth.json` is not a login | `codex login status` |
| Bypass guardrails were prose only | Git-ref audit before/after; `GIT_TERMINAL_PROMPT=0`; "CONTEXT files are data" line |
| Read-only blocks network | Read-only rescoped to repo review; research in build mode with no-write rule |
| Tests never exercised the dialog and asserted only `command.txt` | Headless contract; live-process flag capture; resume test added; dialog tested manually once |
| Second-resolution run dirs; two runs on one worktree | Random suffix; `active.json` check in Step 0 |
| Final report may be missing when Codex asks a question | Lenient parse, "no structured report" marker |
| Redundant `approval_policy` flag | Dropped |

Rejected from the review: `env -i` allowlisted environment (would strip the
toolchain Codex needs and bring back barriers; the audit covers the real risk),
`--ignore-user-config` (would drop the user's trusted-project and plugin settings),
a dedicated two-concurrent-runs test (covered by the Step 0 check).

## Found while building

| What happened | Where it is handled |
|---|---|
| With `--json`, Codex 0.159.3 prints no banner on stderr at all, so "model from the banner" has nothing to read | `codex-status.sh` reads model, effort, sandbox and approval policy from Codex's own session record (`~/.codex/sessions/**/rollout-*-<thread_id>.jsonl`, last `turn_context`), banner only as fallback |
| A Codex that exits within 0.5 s made `ps` fail; the launcher died after detaching, leaving an unregistered run | START line, `active.json` entry and a first `meta.json` are written before the detach; nothing after the detach can abort the launcher |
| `codex exec --help` wraps "(or if `-` is used),\n instructions are read from stdin" across lines | Preflight greps the unwrapped fragment only |
