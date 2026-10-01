#!/usr/bin/env bash
# codex-launch.sh — build and detach one Codex run (attempt-1) or a resume
# (attempt-N) with no approval prompts, no stdin hang and no blocking of the
# calling Claude session. Writes run.json, meta.json, command.txt, the START
# line in runs.log and an entry in active.json, then returns at once.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-launch.sh --dir <abs dir> --model <id> --effort <level> --mode build|readonly \
                  --brief <file> [--slug <name>] [--image <file>]... [--allow-unknown-model]
  codex-launch.sh --resume <run_dir> --model <id> --effort <level> --brief <file> [--image <file>]...

Required: --model and --effort, always (headless contract: there is no default).
  --dir      absolute path Codex works in (build mode: a git worktree on a non-main branch)
  --mode     build    = --dangerously-bypass-approvals-and-sandbox
             readonly = -s read-only (repo review/summary only; cannot be resumed)
  --brief    the prompt file; it is copied into the attempt dir and fed on stdin via `-`
  --resume   continue the run's Codex thread in a new attempt-N dir (build runs only);
             --dir/--mode default to the run's own values
  --image    attach an image (repeatable)
  --slug     short name for the run dir (default: basename of --dir)
  --allow-unknown-model   skip model validation against the cache (failure-path tests only)

Effort above the model's maximum is clamped and a "CLAMPED:" line is printed.
Output (stdout): RUN_DIR=, ATTEMPT_DIR=, PID=, MODEL=, EFFORT= lines.
State lives in ~/.codex-use/ (runs/, runs.log, active.json, last.json).
EOF
}

die() { echo "LAUNCH REFUSED: $*" >&2; exit 1; }

DIR="" MODEL="" EFFORT="" MODE="" BRIEF="" RESUME="" SLUG="" ALLOW_UNKNOWN=0
IMAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --brief) BRIEF="${2:-}"; shift 2 ;;
    --resume) RESUME="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --image) IMAGES+=("${2:-}"); shift 2 ;;
    --allow-unknown-model) ALLOW_UNKNOWN=1; shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v codex >/dev/null 2>&1 || die "codex not found on PATH"
command -v perl >/dev/null 2>&1 || die "perl not found (needed to detach the run)"

STATE="${CODEX_USE_STATE:-$HOME/.codex-use}"   # override only for tests
CACHE="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
mkdir -p "$STATE/runs"
[ -f "$STATE/active.json" ] || echo '[]' > "$STATE/active.json"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- state lock (mkdir is atomic); stale after 30 s ---------------------------
LOCK="$STATE/.lock"
lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i+1))
    if [ $i -gt 60 ]; then rm -rf "$LOCK"; i=0; fi
    sleep 0.5
  done
}
unlock() { rm -rf "$LOCK"; }

jq_inplace() { # $1=file, rest = jq args; atomic replace
  local f="$1"; shift
  jq "$@" "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# --- headless contract ---------------------------------------------------------
[ -n "$MODEL" ] || die "--model is required (ask the user, or supply it in the headless brief)"
[ -n "$EFFORT" ] || die "--effort is required (ask the user, or supply it in the headless brief)"
[ -n "$BRIEF" ] || die "--brief is required"
[ -s "$BRIEF" ] || die "brief file missing or empty: $BRIEF"
BRIEF=$(cd "$(dirname "$BRIEF")" && pwd -P)/$(basename "$BRIEF")

# --- resume: inherit dir/mode/thread from run.json ------------------------------
RUN_DIR=""
THREAD_ID=""
if [ -n "$RESUME" ]; then
  RUN_DIR=$(cd "$RESUME" 2>/dev/null && pwd -P) || die "resume run dir not found: $RESUME"
  [ -f "$RUN_DIR/run.json" ] || die "no run.json in $RUN_DIR"
  R_DIR=$(jq -r .dir "$RUN_DIR/run.json")
  R_MODE=$(jq -r .mode "$RUN_DIR/run.json")
  [ -z "$DIR" ] || [ "$(cd "$DIR" && pwd -P)" = "$R_DIR" ] || die "--dir differs from the run's dir ($R_DIR)"
  [ -z "$MODE" ] || [ "$MODE" = "$R_MODE" ] || die "--mode differs from the run's mode ($R_MODE)"
  DIR="$R_DIR"; MODE="$R_MODE"
  [ "$MODE" = "build" ] || die "read-only runs cannot be resumed (codex exec resume has no -s); launch a new readonly run instead"
  THREAD_ID=$(jq -r '.thread_id // empty' "$RUN_DIR/run.json")
  if [ -z "$THREAD_ID" ]; then
    # persist it from the first attempt's thread.started event if status never ran
    THREAD_ID=$(grep -h '"thread.started"' "$RUN_DIR"/attempt-*/events.jsonl 2>/dev/null | head -1 | jq -r '.thread_id // empty' || true)
    [ -n "$THREAD_ID" ] || die "no thread_id recorded for $RUN_DIR (first attempt never emitted thread.started)"
    jq_inplace "$RUN_DIR/run.json" --arg t "$THREAD_ID" '.thread_id = $t'
  fi
  for a in "$RUN_DIR"/attempt-*; do
    [ -f "$a/exit_code" ] || die "previous attempt still running or never finished: $a (stop or finish it first)"
  done
fi

[ -n "$DIR" ] || die "--dir is required"
case "$DIR" in /*) ;; *) die "--dir must be an absolute path: $DIR" ;; esac
[ -d "$DIR" ] || die "dir not found: $DIR"
DIR=$(cd "$DIR" && pwd -P)
case "$MODE" in build|readonly) ;; *) die "--mode must be build or readonly" ;; esac

# --- one run per dir at a time --------------------------------------------------
BUSY=$(jq -r --arg d "$DIR" '.[] | select(.dir == $d) | .attempt_dir' "$STATE/active.json")
[ -z "$BUSY" ] || die "an unreported run already targets $DIR: $BUSY (finish it with codex-status.sh --finish, or stop it)"

# --- git facts ------------------------------------------------------------------
IS_GIT=false BRANCH="" START_SHA="" COMMON_DIR=""
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=true
  BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  START_SHA=$(git -C "$DIR" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  COMMON_DIR=$(git -C "$DIR" rev-parse --path-format=absolute --git-common-dir)
  if [ "$MODE" = "build" ]; then
    [ -n "$BRANCH" ] || die "build mode needs a branch checked out (HEAD is detached) in $DIR"
    case "$BRANCH" in main|master) die "build mode refuses to run on '$BRANCH'; create a git worktree on a new branch first (git worktree add ../<name> -b <name>)" ;; esac
  fi
fi
if [ "$MODE" = "build" ] && [ "$IS_GIT" = false ]; then
  echo "WARNING: $DIR is not a git repo; build mode runs with no sandbox and no git-ref audit" >&2
fi

# --- model + effort validation --------------------------------------------------
RANKS="minimal low medium high xhigh max ultra"
rank_of() { local i=0 r; for r in $RANKS; do [ "$r" = "$1" ] && { echo $i; return; }; i=$((i+1)); done; echo -1; }
[ "$(rank_of "$EFFORT")" -ge 0 ] || die "unknown effort '$EFFORT' (one of: $RANKS)"
EFFORT_USED="$EFFORT"
CLAMPED=""
if [ -f "$CACHE" ] && jq -e --arg m "$MODEL" '.models[] | select(.slug == $m)' "$CACHE" >/dev/null 2>&1; then
  SUPPORTED=$(jq -r --arg m "$MODEL" '.models[] | select(.slug == $m) | [.supported_reasoning_levels[]?.effort] | join(" ")' "$CACHE")
  MAXE="" MAXR=-1
  for e in $SUPPORTED; do r=$(rank_of "$e"); [ "$r" -gt "$MAXR" ] && { MAXR=$r; MAXE=$e; }; done
  if [ -n "$MAXE" ] && [ "$(rank_of "$EFFORT")" -gt "$MAXR" ]; then
    EFFORT_USED="$MAXE"
    CLAMPED="CLAMPED: effort $EFFORT -> $MAXE (maximum for $MODEL)"
  fi
elif [ "$ALLOW_UNKNOWN" -eq 1 ]; then
  echo "WARNING: model '$MODEL' is not in the model cache; launching anyway (--allow-unknown-model)" >&2
else
  VALID=$(jq -r '[.models[] | select((.visibility // "list") == "list") | .slug] | join(", ")' "$CACHE" 2>/dev/null || echo "?")
  die "model '$MODEL' is not in the Codex model cache. Valid: $VALID"
fi

for img in ${IMAGES[@]+"${IMAGES[@]}"}; do [ -f "$img" ] || die "image not found: $img"; done

# --- run + attempt dirs -----------------------------------------------------------
if [ -z "$RUN_DIR" ]; then
  [ -n "$SLUG" ] || SLUG=$(basename "$DIR")
  SLUG=$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
  [ -n "$SLUG" ] || SLUG=run
  HEX=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
  RUN_DIR="$STATE/runs/$(date +%Y%m%d-%H%M%S)-$SLUG-$HEX"
  mkdir -p "$RUN_DIR"
  REFS='{}'
  if [ -n "$COMMON_DIR" ]; then
    REFS=$(git --git-dir="$COMMON_DIR" for-each-ref --format='%(refname) %(objectname)' \
      | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries')
  fi
  jq -n --arg run_dir "$RUN_DIR" --arg dir "$DIR" --arg branch "$BRANCH" --arg start_sha "$START_SHA" \
     --arg mode "$MODE" --arg common "$COMMON_DIR" --argjson is_git "$IS_GIT" \
     --argjson refs "$REFS" --arg created "$(now_iso)" \
     '{run_dir:$run_dir, dir:$dir, is_git:$is_git, branch:$branch, start_sha:$start_sha, mode:$mode,
       thread_id:null, git_common_dir:$common, refs_before:$refs, created:$created}' > "$RUN_DIR/run.json"
  N=1
else
  N=$(( $(ls -d "$RUN_DIR"/attempt-* 2>/dev/null | sed 's/.*attempt-//' | sort -n | tail -1) + 1 ))
fi
ATT="$RUN_DIR/attempt-$N"
mkdir -p "$ATT"
cp "$BRIEF" "$ATT/brief.md"

# --- the command (only flags present in the relevant --help) ----------------------
CMD=(codex exec)
[ -n "$THREAD_ID" ] && CMD+=(resume)
CMD+=(-m "$MODEL" -c "model_reasoning_effort=$EFFORT_USED")
if [ "$MODE" = "build" ]; then CMD+=(--dangerously-bypass-approvals-and-sandbox); else CMD+=(-s read-only); fi
[ "$IS_GIT" = true ] || CMD+=(--skip-git-repo-check)
for img in ${IMAGES[@]+"${IMAGES[@]}"}; do CMD+=(-i "$(cd "$(dirname "$img")" && pwd -P)/$(basename "$img")"); done
CMD+=(--json -o "$ATT/last-message.md")
[ -n "$THREAD_ID" ] && CMD+=("$THREAD_ID")
CMD+=(-)

Q=""; for a in "${CMD[@]}"; do Q="$Q $(printf '%q' "$a")"; done; Q="${Q# }"
{
  echo "cd $(printf '%q' "$DIR")"
  echo "GIT_TERMINAL_PROMPT=0 $Q < $(printf '%q' "$ATT/brief.md") >> $(printf '%q' "$ATT/events.jsonl") 2>> $(printf '%q' "$ATT/stderr.log")"
} > "$ATT/command.txt"

# Wrapper: run Codex, then publish the exit code atomically (tmp + mv).
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'ATT=%q\n' "$ATT"
  printf 'DIR=%q\n' "$DIR"
  cat <<'EOF'
publish() { printf '%s\n' "$1" > "$ATT/exit_code.tmp"; mv -f "$ATT/exit_code.tmp" "$ATT/exit_code"; }
cd "$DIR" || { publish 127; exit 127; }
export GIT_TERMINAL_PROMPT=0
rc=0
EOF
  printf '%s < "$ATT/brief.md" >> "$ATT/events.jsonl" 2>> "$ATT/stderr.log" || rc=$?\n' "$Q"
  printf '%s\n' 'publish "$rc"'
} > "$ATT/wrapper.sh"
chmod +x "$ATT/wrapper.sh"
: > "$ATT/events.jsonl"; : > "$ATT/stderr.log"

# --- meta + registry BEFORE detaching, so a crash below never leaves an unseen run --
STARTED=$(now_iso); STARTED_EPOCH=$(date +%s)
HEAD_SHA=""
[ "$IS_GIT" = true ] && HEAD_SHA=$(git -C "$DIR" rev-parse --verify --quiet HEAD 2>/dev/null || true)
jq -n --arg head "$HEAD_SHA" --arg model "$MODEL" --arg effort "$EFFORT" --arg effort_used "$EFFORT_USED" --arg mode "$MODE" \
   --argjson attempt "$N" --argjson resume "$( [ -n "$THREAD_ID" ] && echo true || echo false )" \
   --arg started "$STARTED" --argjson started_epoch "$STARTED_EPOCH" \
   '{model:$model, effort_requested:$effort, effort:$effort_used, mode:$mode, attempt:$attempt,
     resume:$resume, head_at_start:$head, started:$started, started_epoch:$started_epoch, pid:null, pgid:null,
     pid_start:null, live_command:null, live_group_commands:[], finished:null, exit_code:null, usage:null}' \
   > "$ATT/meta.json"
lock
trap unlock EXIT
echo "$STARTED START run=$RUN_DIR attempt=$N model=$MODEL effort=$EFFORT_USED mode=$MODE dir=$DIR" >> "$STATE/runs.log"
jq_inplace "$STATE/active.json" --arg r "$RUN_DIR" --arg a "$ATT" --arg d "$DIR" --arg s "$STARTED" \
  '. + [{run_dir:$r, attempt_dir:$a, dir:$d, pid:null, pid_start:null, started:$s}]'
if [ "$ALLOW_UNKNOWN" -eq 0 ]; then
  jq -n --arg m "$MODEL" --arg e "$EFFORT_USED" --arg t "$(now_iso)" '{model:$m, effort:$e, updated:$t}' > "$STATE/last.json"
fi
unlock
trap - EXIT

# --- detach: new session + process group, no tie to the caller's terminal ---------
perl -MPOSIX -e 'defined(POSIX::setsid()) or die "setsid: $!"; exec @ARGV or die "exec: $!"' \
  -- bash "$ATT/wrapper.sh" </dev/null >/dev/null 2>>"$ATT/stderr.log" &
PID=$!
disown "$PID" 2>/dev/null || true

# From here on nothing may abort the script: the run is live.
set +e
# give it ~1 s, then capture identity + the live Codex command line
PID_START="" PGID="" LIVE="" LIVE_ALL="[]"
for i in 1 2 3 4 5 6; do
  sleep 0.5
  s=$( (ps -o lstart= -p "$PID" 2>/dev/null || true) | sed 's/^ *//; s/ *$//')
  [ -n "$s" ] && PID_START="$s"
  g=$( (ps -o pgid= -p "$PID" 2>/dev/null || true) | tr -d ' ')
  [ -n "$g" ] && PGID="$g"
  l=$( (ps -ax -o pgid= -o command= 2>/dev/null | awk -v g="$PID" '$1==g {sub(/^ *[0-9]+ +/,""); print}' || true) | jq -Rn '[inputs]' 2>/dev/null)
  [ -n "$l" ] && [ "$l" != "[]" ] && LIVE_ALL="$l"
  LIVE=$(jq -r '[.[] | select(test("codex exec"))] | first // empty' <<<"$LIVE_ALL" 2>/dev/null)
  [ $i -ge 2 ] && [ -n "$LIVE" ] && break
  [ -f "$ATT/exit_code" ] && break
done
if [ -n "$PGID" ] && [ "$PGID" != "$PID" ]; then
  echo "WARNING: pgid $PGID != pid $PID; codex-stop.sh will refuse a group kill" >&2
fi
[ -n "$PID_START" ] || echo "WARNING: process $PID exited before its start time was captured (see codex-status.sh)" >&2

jq_inplace "$ATT/meta.json" --argjson pid "$PID" --arg pgid "$PGID" --arg ps "$PID_START" \
   --arg live "$LIVE" --argjson live_all "$LIVE_ALL" \
   '.pid = $pid | .pgid = ($pgid | tonumber? // null) | .pid_start = $ps
    | .live_command = $live | .live_group_commands = $live_all'
lock
jq_inplace "$STATE/active.json" --arg a "$ATT" --argjson p "$PID" --arg ps "$PID_START" \
  'map(if .attempt_dir == $a then .pid = $p | .pid_start = $ps else . end)'
unlock

[ -z "$CLAMPED" ] || echo "$CLAMPED"
echo "RUN_DIR=$RUN_DIR"
echo "ATTEMPT_DIR=$ATT"
echo "PID=$PID"
echo "MODEL=$MODEL"
echo "EFFORT=$EFFORT_USED"
[ -z "$THREAD_ID" ] || echo "THREAD_ID=$THREAD_ID"
exit 0
