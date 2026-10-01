#!/usr/bin/env bash
# codex-preflight.sh — check that Codex CLI is installed, logged in, still has the
# flags the launcher relies on, and list models + efforts from the model cache.
# Prints ONE JSON object on stdout. Exits 1 on a hard failure (reason in .reason
# and as a "PREFLIGHT FAIL:" line on stderr).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex-preflight.sh [--no-refresh]

Checks, in order:
  1. codex on PATH, version string
  2. `codex login status` reports a login
  3. anchored flag greps in `codex exec --help` AND `codex exec resume --help`
  4. models + supported efforts from ~/.codex/models_cache.json; stale when the
     cache's client_version differs from `codex --version`, then refreshed by a
     one-word read-only probe in a temp dir (skip with --no-refresh)
  5. ~/.codex-use/last.json and recent models from ~/.codex-use/runs.log

Output: one JSON object (ok, version, logged_in, models[], last, recent_models,
warnings[]). Exit 0 = usable, 1 = hard failure.
EOF
}

NO_REFRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-refresh) NO_REFRESH=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

STATE="${CODEX_USE_STATE:-$HOME/.codex-use}"   # override only for tests
CACHE="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
mkdir -p "$STATE/runs"
WARNINGS='[]'

warn() { WARNINGS=$(jq -c --arg w "$1" '. + [$w]' <<<"$WARNINGS"); }

fail() {
  echo "PREFLIGHT FAIL: $1" >&2
  jq -n --arg r "$1" --argjson w "$WARNINGS" '{ok:false, reason:$r, warnings:$w}'
  exit 1
}

command -v jq >/dev/null 2>&1 || { echo "PREFLIGHT FAIL: jq not found" >&2; echo '{"ok":false,"reason":"jq not found"}'; exit 1; }

command -v perl >/dev/null 2>&1 || fail "perl not found (needed to detach runs and as a timeout)"

# 1. binary + version
CODEX_PATH=$(command -v codex 2>/dev/null || true)
[ -n "$CODEX_PATH" ] || fail "codex not found on PATH"
VERSION_RAW=$(codex --version 2>/dev/null || true)
VERSION=$(printf '%s' "$VERSION_RAW" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
[ -n "$VERSION" ] || fail "could not parse codex --version output: $VERSION_RAW"

# 2. login (a file in ~/.codex is not proof; the CLI's own answer is)
LOGIN_TEXT=$(codex login status 2>&1 </dev/null || true)
if ! grep -qi 'logged in' <<<"$LOGIN_TEXT"; then
  fail "not logged in ($LOGIN_TEXT). Run 'codex login' in your own terminal."
fi
if grep -qi 'not logged in' <<<"$LOGIN_TEXT"; then
  fail "not logged in ($LOGIN_TEXT). Run 'codex login' in your own terminal."
fi

# 3. flag drift alarm: anchored patterns, both help texts
EXEC_HELP=$(codex exec --help 2>&1 </dev/null || true)
RESUME_HELP=$(codex exec resume --help 2>&1 </dev/null || true)
S='^[[:space:]]+'
check_flag() { # $1=help text  $2=label  $3=regex  $4=flag name
  if ! grep -Eq -- "$3" <<<"$1"; then
    fail "flag missing from '$2 --help': $4 (Codex CLI changed; update the skill before launching)"
  fi
}
check_flag "$EXEC_HELP" "codex exec" "${S}-m, --model " "-m/--model"
check_flag "$EXEC_HELP" "codex exec" "${S}-c, --config " "-c/--config"
check_flag "$EXEC_HELP" "codex exec" "${S}-s, --sandbox " "-s/--sandbox"
check_flag "$EXEC_HELP" "codex exec" "${S}--dangerously-bypass-approvals-and-sandbox" "--dangerously-bypass-approvals-and-sandbox"
check_flag "$EXEC_HELP" "codex exec" "${S}--skip-git-repo-check" "--skip-git-repo-check"
check_flag "$EXEC_HELP" "codex exec" "${S}--ephemeral" "--ephemeral"
check_flag "$EXEC_HELP" "codex exec" "${S}-i, --image " "-i/--image"
check_flag "$EXEC_HELP" "codex exec" "${S}--json" "--json"
check_flag "$EXEC_HELP" "codex exec" "${S}-o, --output-last-message " "-o/--output-last-message"
check_flag "$EXEC_HELP" "codex exec" 'or if `-` is used' "'-' reads prompt from stdin"
check_flag "$RESUME_HELP" "codex exec resume" "${S}-m, --model " "-m/--model"
check_flag "$RESUME_HELP" "codex exec resume" "${S}-c, --config " "-c/--config"
check_flag "$RESUME_HELP" "codex exec resume" "${S}--dangerously-bypass-approvals-and-sandbox" "--dangerously-bypass-approvals-and-sandbox"
check_flag "$RESUME_HELP" "codex exec resume" "${S}--skip-git-repo-check" "--skip-git-repo-check"
check_flag "$RESUME_HELP" "codex exec resume" "${S}-i, --image " "-i/--image"
check_flag "$RESUME_HELP" "codex exec resume" "${S}--json" "--json"
check_flag "$RESUME_HELP" "codex exec resume" "${S}-o, --output-last-message " "-o/--output-last-message"
check_flag "$RESUME_HELP" "codex exec resume" 'If `-` is used, read from stdin' "'-' reads prompt from stdin (resume)"

# 4. models cache, staleness keyed on client_version
cache_version() { jq -r '.client_version // empty' "$CACHE" 2>/dev/null || true; }
CACHE_VERSION=""
[ -f "$CACHE" ] && CACHE_VERSION=$(cache_version)
CACHE_STALE=false
CACHE_REFRESHED=false
if [ ! -f "$CACHE" ] || [ "$CACHE_VERSION" != "$VERSION" ]; then
  CACHE_STALE=true
  if [ "$NO_REFRESH" -eq 0 ]; then
    PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-use-probe.XXXXXX")
    # perl alarm = portable timeout (macOS has no `timeout`); 120 s cap
    ( cd "$PROBE_DIR" && perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 120 \
        codex exec --skip-git-repo-check -s read-only --ephemeral - <<<"Reply ok" >/dev/null 2>&1 ) || true
    rm -rf "$PROBE_DIR"
    [ -f "$CACHE" ] && CACHE_VERSION=$(cache_version)
    if [ -f "$CACHE" ] && [ "$CACHE_VERSION" = "$VERSION" ]; then
      CACHE_STALE=false; CACHE_REFRESHED=true
    else
      warn "model cache did not refresh (cache client_version '${CACHE_VERSION:-none}' vs CLI $VERSION); using the old list"
    fi
  else
    warn "model cache is stale (client_version '${CACHE_VERSION:-none}' vs CLI $VERSION); refresh skipped"
  fi
fi
[ -f "$CACHE" ] || fail "no model cache at $CACHE even after a probe; cannot validate models"

MODELS=$(jq -c '
  ["minimal","low","medium","high","xhigh","max","ultra"] as $rank
  | [.models[]
     | {slug,
        display_name: (.display_name // .slug),
        visibility: (.visibility // "list"),
        priority: (.priority // 999),
        default_effort: (.default_reasoning_level // null),
        efforts: [.supported_reasoning_levels[]?.effort]}
     | . + {max_effort: (.efforts | sort_by(. as $e | ($rank | index($e)) // -1) | last)}]
  | sort_by(.priority)' "$CACHE")

# 5. last-used + recent models (newest first, unique) from runs.log START lines
LAST='null'
[ -f "$STATE/last.json" ] && LAST=$(jq -c . "$STATE/last.json" 2>/dev/null || echo null)
RECENT='[]'
if [ -f "$STATE/runs.log" ]; then
  RECENT=$( (grep ' START ' "$STATE/runs.log" || true) | sed -n 's/.* model=\([^ ]*\).*/\1/p' \
    | awk '{a[NR]=$0} END {for (i=NR;i>0;i--) if (!s[a[i]]++) print a[i]}' \
    | jq -R . | jq -sc --argjson m "$MODELS" '[.[] | select(. as $s | $m | any(.slug == $s))]')
fi

jq -n \
  --arg path "$CODEX_PATH" --arg version "$VERSION" --arg login "$LOGIN_TEXT" \
  --arg cache "$CACHE" --arg cache_version "$CACHE_VERSION" \
  --argjson stale "$CACHE_STALE" --argjson refreshed "$CACHE_REFRESHED" \
  --argjson models "$MODELS" --argjson last "$LAST" --argjson recent "$RECENT" \
  --argjson warnings "$WARNINGS" \
  '{ok:true, codex_path:$path, version:$version, logged_in:true, login_text:$login,
    flags_ok:true, cache:$cache, cache_client_version:$cache_version,
    cache_stale:$stale, cache_refreshed:$refreshed,
    models:$models, last:$last, recent_models:$recent, warnings:$warnings}'
