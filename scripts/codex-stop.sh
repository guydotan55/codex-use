#!/usr/bin/env bash
# codex-stop.sh — stop one detached Codex attempt cleanly: verify identity,
# TERM its process group, wait 10 s, KILL, publish exit_code 143, show git state.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex-stop.sh <attempt_dir>

Checks that the recorded pid is alive with the recorded start time and that
pgid == pid (so the group cannot be the Claude shell's), then sends TERM to the
process group, waits up to 10 s, then KILL. Writes exit_code 143 if the wrapper
did not. Prints the last commit on the branch and `git status --short`.
Uncommitted work since Codex's last commit is lost. Afterwards run
codex-status.sh --finish <attempt_dir> to close the registry entry.
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac
ATT=$(cd "$1" 2>/dev/null && pwd -P) || { echo "codex-stop: attempt dir not found: $1" >&2; exit 1; }
META="$ATT/meta.json"; RUN=$(dirname "$ATT")
[ -f "$META" ] || { echo "codex-stop: no meta.json in $ATT" >&2; exit 1; }

PID=$(jq -r '.pid // empty' "$META")
WANT=$(jq -r '.pid_start // empty' "$META")

publish_143() {
  if [ ! -f "$ATT/exit_code" ]; then
    printf '143\n' > "$ATT/exit_code.tmp" && mv -f "$ATT/exit_code.tmp" "$ATT/exit_code"
    echo "exit_code 143 written"
  fi
}

group_alive() { ps -ax -o pgid= 2>/dev/null | awk -v g="$PID" '$1==g {f=1} END {exit !f}'; }

if [ -f "$ATT/exit_code" ]; then
  echo "already finished (exit_code $(cat "$ATT/exit_code")); nothing to stop"
else
  NOW_START=$(ps -o lstart= -p "$PID" 2>/dev/null | sed 's/^ *//; s/ *$//' || true)
  if [ -z "$NOW_START" ]; then
    echo "pid $PID is gone; the attempt died without an exit_code"
    publish_143
  elif [ "$NOW_START" != "$WANT" ]; then
    echo "codex-stop: pid $PID was reused by another process (start '$NOW_START' != '$WANT'); not killing" >&2
    publish_143
  else
    PGID=$(ps -o pgid= -p "$PID" | tr -d ' ')
    if [ "$PGID" != "$PID" ]; then
      echo "codex-stop: pgid $PGID != pid $PID; refusing a group kill (it could hit the caller's shell)" >&2
      exit 1
    fi
    echo "sending TERM to process group $PID"
    kill -TERM -- "-$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do group_alive || break; sleep 1; done
    if group_alive; then
      echo "still alive after 10 s; sending KILL"
      kill -KILL -- "-$PID" 2>/dev/null || true
      sleep 1
    fi
    group_alive && echo "WARNING: processes remain in group $PID" >&2
    publish_143
  fi
fi

DIR=$(jq -r .dir "$RUN/run.json")
if [ "$(jq -r .is_git "$RUN/run.json")" = "true" ]; then
  echo "last commit: $(git -C "$DIR" log -1 --oneline 2>/dev/null || echo none)"
  echo "git status --short:"
  git -C "$DIR" status --short | sed 's/^/  /'
fi
echo "next: codex-status.sh --finish $ATT"
