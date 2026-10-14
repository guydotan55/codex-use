# Changelog

## 0.2.0 - 2026-10-14

- New verify step: after every build, Claude runs the commands under Codex's "How to verify" (or the project's own tests), and starts the app when there is one. Failures lead the report as `**FAILS: <command>**`, ahead of Codex's "Done".
- The brief asks Codex for "How to verify" as exact, runnable commands.
- The fix round is only done when every verify command passes.

## 0.1.0 - 2026-10-01

Initial public release.

- Preflight, launch, status and stop scripts for driving `codex exec` from Claude Code.
- Model and effort validated against Codex's model cache; effort clamped per model.
- Detached runs with start verification, state in `~/.codex-use/`, resume fix rounds.
- Build mode in a git worktree with a git-ref audit.
