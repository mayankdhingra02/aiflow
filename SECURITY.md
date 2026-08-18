# Security policy

Aiflow sits between model output and local source-code repositories, so its primary security goal
is to prevent untrusted text from becoming trusted local execution configuration.

## Current protections

- Repository paths are resolved from a local SQLite registry, never from model output.
- Every packet is bound to a task ID, project ID, one-time nonce, workflow stage, and base commit.
- Duplicate packet IDs are rejected.
- Git remote credentials, query parameters, and fragments are removed before storage or prompt use.
- Accepted implementation roles and reasoning levels are allowlisted.
- Codex runs use the fixed `workspace-write` sandbox.
- Execution is a dry run unless the user explicitly passes `--execute`.
- Sensitive, Sol, or xhigh recommendations require `--approve-high-risk` in addition to execution.

## Not yet implemented

- Background clipboard watcher.
- macOS floating widget.
- Automatic validation-command execution.
- Git worktree isolation.
- Review/fix packets.
- Automatic commits, pushes, pull requests, or merges.

These features must not be represented as complete until they are implemented and tested.

## Reporting a vulnerability

Do not include credentials, access tokens, private source code, or sensitive clipboard contents in
a public issue. Provide a minimal reproduction using a disposable repository and synthetic data.
