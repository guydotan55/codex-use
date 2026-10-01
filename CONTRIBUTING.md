# Contributing

Issues and pull requests are welcome.

- Keep the scripts bash 3.2 compatible and portable across macOS and Linux (no GNU-only or BSD-only flags without a fallback).
- Run `bash -n` and `shellcheck` on every script you change; do not add new warnings.
- Flags and event shapes in `references/cli-reference.md` were checked against a real Codex CLI. If you change behavior, say which Codex version you tested on.
- Never put real paths, tokens or personal details in the repo.
- Keep the Safety section accurate: if a change weakens a guardrail, say so in the PR.
