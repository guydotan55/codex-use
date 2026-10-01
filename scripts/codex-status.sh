#!/usr/bin/env bash
# codex-status.sh — read-only status of Codex runs started by codex-launch.sh,
# plus the two bookkeeping actions of the finish step (--audit, --finish).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-status.sh <attempt_dir>             human summary (state, elapsed, last item, commits, dirty files, model)
  codex-status.sh --started <attempt_dir>   exit 0 once Codex has started a turn (or already failed/exited)
  codex-status.sh --terminal <attempt_dir>  exit 0 once the attempt is over (turn.completed/failed, exit_code, or pid gone)
  codex-status.sh --audit <run_dir>         compare the main repository's refs with refs_before; exit 2 on a breach
  codex-status.sh --list                    every run in active.json: running / finished-unreported / died
  codex-status.sh --finish <attempt_dir>    write END line to runs.log, record usage in meta.json, drop from active.json

--started and --terminal print one line when they succeed and nothing otherwise,
so they fit an until-loop inside a Monitor. Every mode also persists the run's
thread_id into run.json the first time a thread.started event is seen.
EOF
}

STATE="${CODEX_USE_STATE:-$HOME/.codex-use}"   # override only for tests
CODEX_SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"
die() { echo "codex-status: $*" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
jq_inplace() { local f="$1"; shift; jq "$@" "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; }

LOCK="$STATE/.lock"
lock() { local i=0; until mkdir "$LOCK" 2>/dev/null; do i=$((i+1)); if [ $i -gt 60 ]; then rm -rf "$LOCK"; i=0; fi; sleep 0.5; done; }
unlock() { rm -rf "$LOCK"; }

# --- helpers on one attempt -------------------------------------------------------
load_attempt() { # sets ATT RUN META EV
  ATT=$(cd "$1" 2>/dev/null && pwd -P) || die "attempt dir not found: $1"
  RUN=$(dirname "$ATT")
  META="$ATT/meta.json"; EV="$ATT/events.jsonl"
  [ -f "$META" ] || die "no meta.json in $ATT"
  [ -f "$RUN/run.json" ] || die "no run.json in $RUN"
  persist_thread
}

has_event() { [ -s "$EV" ] && grep -Eq "\"type\":\"($1)\"" "$EV"; }

persist_thread() {
  local t cur
  cur=$(jq -r '.thread_id // empty' "$RUN/run.json")
  [ -z "$cur" ] || return 0
  [ -s "$EV" ] || return 0
  t=$( (grep -m1 '"type":"thread.started"' "$EV" || true) | jq -r '.thread_id // empty' 2>/dev/null || true)
  [ -n "$t" ] || return 0
  jq_inplace "$RUN/run.json" --arg t "$t" '.thread_id = $t'
}

pid_alive() { # alive AND same process (start time matches)
  local pid ps_start want
  pid=$(jq -r '.pid // empty' "$META"); want=$(jq -r '.pid_start // empty' "$META")
  [ -n "$pid" ] || return 1
  ps_start=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//' || true)
  [ -n "$ps_start" ] && [ "$ps_start" = "$want" ]
}

state_of() { # finished-ok | finished-failed | finishing | running | starting | died
  if [ -f "$ATT/exit_code" ]; then
    if [ "$(cat "$ATT/exit_code")" = "0" ] && has_event 'turn\.completed'; then echo finished-ok; else echo finished-failed; fi
  elif pid_alive; then
    if has_event 'turn\.completed|turn\.failed'; then echo finishing
    elif has_event 'turn\.started'; then echo running
    else echo starting; fi
  else
    echo died
  fi
}

reported_model() { # model/effort/sandbox as Codex itself recorded them
  local thread rollout line
  thread=$( (grep -m1 '"type":"thread.started"' "$EV" 2>/dev/null || true) | jq -r '.thread_id // empty' 2>/dev/null || true)
  [ -n "$thread" ] || thread=$(jq -r '.thread_id // empty' "$RUN/run.json")
  if [ -n "$thread" ] && [ -d "$CODEX_SESSIONS" ]; then
    rollout=$(find "$CODEX_SESSIONS" -name "rollout-*-$thread.jsonl" -mtime -30 2>/dev/null | head -1 || true)
    if [ -n "$rollout" ]; then
      line=$( (grep '"type":"turn_context"' "$rollout" || true) | tail -1 | jq -r '.payload | "model=\(.model) effort=\(.collaboration_mode.settings.reasoning_effort // .effort // "?") sandbox=\(.sandbox_policy.type // "?") approval=\(.approval_policy // "?")"' 2>/dev/null || true)
      [ -n "$line" ] && { echo "$line (Codex session record)"; return; }
    fi
  fi
  line=$(grep -Eim1 '^[[:space:]]*model:' "$ATT/stderr.log" 2>/dev/null || true)
  [ -n "$line" ] && { echo "$line (stderr banner)"; return; }
  echo "unknown (no session record or banner yet)"
}

item_summary() { # last item.* event, one line
  [ -s "$EV" ] || { echo "none"; return; }
  (grep '"type":"item\.' "$EV" || true) | tail -1 | jq -r '
    .type as $t | .item as $i
    | ($i.type // "?") as $k
    | ( $i.command // ($i.changes // [] | map("\(.kind // "") \(.path)") | join(", ") | select(. != ""))
        // $i.query // $i.text // $i.message // "" ) as $s
    | "\($t) \($k): \($s | tostring | gsub("\n"; " ") | .[0:160])"' 2>/dev/null || echo "unparseable"
}

errors_verbatim() {
  [ -s "$EV" ] || return 0
  (grep -E '"type":"(turn\.failed|error)"' "$EV" || true) | jq -r '
    if .type == "turn.failed" then "turn.failed: \(.error.message // (.error|tostring))"
    elif .type == "item.completed" and .item.type == "error" then "warning (item): \(.item.message // .item.text // (.item|tostring))"
    elif .type == "item.started" and .item.type == "error" then empty
    else "error: \(.message // tostring)" end' 2>/dev/null || true
}

elapsed_s() {
  local s e
  s=$(jq -r '.started_epoch' "$META")
  if [ -f "$ATT/exit_code" ]; then e=$(stat -c %Y "$ATT/exit_code" 2>/dev/null || stat -f %m "$ATT/exit_code"); else e=$(date +%s); fi
  echo $((e - s))
}

# --- modes --------------------------------------------------------------------------
summary() {
  load_attempt "$1"
  local st dir sha commits dirty
  st=$(state_of)
  dir=$(jq -r .dir "$RUN/run.json"); sha=$(jq -r '.start_sha // empty' "$RUN/run.json")
  echo "state:        $st"
  echo "attempt:      $ATT"
  echo "requested:    model=$(jq -r .model "$META") effort=$(jq -r .effort "$META") mode=$(jq -r .mode "$META")"
  echo "codex says:   $(reported_model)"
  echo "thread:       $(jq -r '.thread_id // "not yet"' "$RUN/run.json")"
  echo "elapsed:      $(elapsed_s)s"
  echo "items done:   $(grep -c '"type":"item.completed"' "$EV" 2>/dev/null || true)"
  echo "last item:    $(item_summary)"
  if [ "$(jq -r .is_git "$RUN/run.json")" = "true" ]; then
    commits=0; [ -n "$sha" ] && commits=$(git -C "$dir" rev-list --count "$sha..HEAD" 2>/dev/null || echo "?")
    dirty=$(git -C "$dir" status --short 2>/dev/null | wc -l | tr -d ' ')
    echo "commits:      $commits since run start ${sha:0:9}"
    local h; h=$(jq -r '.head_at_start // empty' "$META")
    if [ -n "$h" ] && [ "$h" != "$sha" ]; then
      echo "              $(git -C "$dir" rev-list --count "$h..HEAD" 2>/dev/null || echo "?") since this attempt's start ${h:0:9}"
    fi
    echo "dirty files:  $dirty"
  fi
  [ -f "$ATT/exit_code" ] && echo "exit_code:    $(cat "$ATT/exit_code")"
  if [ -f "$ATT/last-message.md" ]; then echo "last message: present ($(wc -l < "$ATT/last-message.md" | tr -d ' ') lines)"; else echo "last message: absent"; fi
  local errs; errs=$(errors_verbatim)
  [ -z "$errs" ] || { echo "errors (verbatim):"; printf '%s\n' "$errs" | sed 's/^/  /'; }
  if [ "$st" = "died" ] || { [ "$st" = "starting" ] && [ "$(elapsed_s)" -gt 90 ]; }; then
    echo "stderr tail:"; tail -5 "$ATT/stderr.log" 2>/dev/null | sed 's/^/  /' || true
  fi
}

started() {
  load_attempt "$1"
  if has_event 'turn\.started|item\.[a-z_]+|turn\.failed|error'; then
    echo "STARTED $(state_of) $ATT"; exit 0
  fi
  if [ -f "$ATT/exit_code" ]; then echo "EXITED exit_code=$(cat "$ATT/exit_code") $ATT"; exit 0; fi
  exit 1
}

terminal() {
  load_attempt "$1"
  if [ -f "$ATT/exit_code" ]; then echo "TERMINAL $(state_of) exit_code=$(cat "$ATT/exit_code") $ATT"; exit 0; fi
  if has_event 'turn\.completed|turn\.failed'; then
    # the turn is over; give the wrapper up to 10 s to publish exit_code and -o
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$ATT/exit_code" ] && break; sleep 1; done
    echo "TERMINAL $(state_of) exit_code=$(cat "$ATT/exit_code" 2>/dev/null || echo none) $ATT"; exit 0
  fi
  if ! pid_alive; then echo "TERMINAL died (pid gone, no exit_code) $ATT"; exit 0; fi
  exit 1
}

audit() {
  local run; run=$(cd "$1" 2>/dev/null && pwd -P) || die "run dir not found: $1"
  local rj="$run/run.json"; [ -f "$rj" ] || die "no run.json in $run"
  local common branch; common=$(jq -r '.git_common_dir // empty' "$rj"); branch=$(jq -r '.branch // empty' "$rj")
  [ -n "$common" ] || { echo "AUDIT SKIPPED: not a git run"; exit 0; }
  local now; now=$(git --git-dir="$common" for-each-ref --format='%(refname) %(objectname)' \
      | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries')
  local out
  out=$(jq -rn --argjson b "$(jq '.refs_before' "$rj")" --argjson a "$now" --arg own "refs/heads/$branch" '
    ([$b, $a] | map(keys) | add | unique)[] as $r
    | select($r != $own)
    | select($b[$r] != $a[$r])
    | "**BREACH** \($r): \($b[$r] // "absent") -> \($a[$r] // "deleted")"')
  local ownb owna
  ownb=$(jq -r --arg own "refs/heads/$branch" '.refs_before[$own] // "absent"' "$rj")
  owna=$(jq -r --arg own "refs/heads/$branch" '.[$own] // "deleted"' <<<"$now")
  echo "run branch refs/heads/$branch: ${ownb:0:9} -> ${owna:0:9}"
  if [ -z "$out" ]; then echo "AUDIT OK: no foreign ref changes"; exit 0; fi
  printf '%s\n' "$out"; exit 2
}

list() {
  [ -f "$STATE/active.json" ] || { echo "no active codex runs"; exit 0; }
  local n; n=$(jq 'length' "$STATE/active.json")
  [ "$n" -gt 0 ] || { echo "no active codex runs"; exit 0; }
  local a st
  for a in $(jq -r '.[].attempt_dir' "$STATE/active.json"); do
    if [ ! -d "$a" ]; then echo "missing    $a (attempt dir gone)"; continue; fi
    st=$( (load_attempt "$a" >/dev/null; state_of) ) || st=unknown
    case "$st" in
      finished-*) echo "finished-unreported ($st)  $a" ;;
      died) echo "died  $a" ;;
      *) echo "running ($st)  $a" ;;
    esac
  done
}

finish() {
  load_attempt "$1"
  local st; st=$(state_of)
  case "$st" in running|starting|finishing) die "attempt is still $st; wait for --terminal or use codex-stop.sh" ;; esac
  local code dur usage report
  code=$(cat "$ATT/exit_code" 2>/dev/null || echo none)
  dur=$(elapsed_s)
  usage=$( (grep '"type":"turn.completed"' "$EV" 2>/dev/null || true) | tail -1 | jq -c '.usage // null' 2>/dev/null || true)
  [ -n "$usage" ] || usage=null
  if [ ! -f "$ATT/last-message.md" ]; then report="missing"
  elif grep -q '^## Done' "$ATT/last-message.md" && grep -q '^## Not done' "$ATT/last-message.md" \
       && grep -q '^## Assumptions' "$ATT/last-message.md" && grep -q '^## How to verify' "$ATT/last-message.md"; then report="structured"
  else report="no structured report"; fi
  jq_inplace "$META" --arg f "$(now_iso)" --arg c "$code" --argjson u "$usage" --arg st "$st" --arg r "$report" \
    '.finished = $f | .exit_code = ($c | tonumber? // $c) | .usage = $u | .outcome = $st | .report = $r'
  local tok
  tok=$(jq -r 'if . == null then "tokens=none" else "input_tokens=\(.input_tokens // 0) cached_input_tokens=\(.cached_input_tokens // 0) output_tokens=\(.output_tokens // 0) reasoning_output_tokens=\(.reasoning_output_tokens // 0)" end' <<<"$usage")
  lock; trap unlock EXIT
  echo "$(now_iso) END run=$RUN attempt=$(jq -r .attempt "$META") exit=$code outcome=$st duration_s=$dur $tok" >> "$STATE/runs.log"
  [ -f "$STATE/active.json" ] && jq_inplace "$STATE/active.json" --arg a "$ATT" 'map(select(.attempt_dir != $a))'
  unlock; trap - EXIT
  echo "FINISHED outcome=$st exit=$code duration_s=$dur $tok report=$report"
  [ "$st" = "finished-ok" ] || echo "NOTE: not a success (outcome $st); treat the run as failed"
}

[ $# -gt 0 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage ;;
  --started) [ $# -eq 2 ] || die "--started needs <attempt_dir>"; started "$2" ;;
  --terminal) [ $# -eq 2 ] || die "--terminal needs <attempt_dir>"; terminal "$2" ;;
  --audit) [ $# -eq 2 ] || die "--audit needs <run_dir>"; audit "$2" ;;
  --list) list ;;
  --finish) [ $# -eq 2 ] || die "--finish needs <attempt_dir>"; finish "$2" ;;
  -*) usage >&2; exit 2 ;;
  *) summary "$1" ;;
esac
