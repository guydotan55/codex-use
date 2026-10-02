# Security

## Reporting

Report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab of this repository). Please do not open a public issue for them.

## Threat model

Build mode runs Codex with `--dangerously-bypass-approvals-and-sandbox`: no approval prompts and no sandbox. The guardrails (worktree-only, git-ref audit, brief rules) reduce accidents but do not contain a hostile or confused agent. Read the Safety section of the [README](README.md#safety) before use, and do not run it against untrusted repositories or briefs.
