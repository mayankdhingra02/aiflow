# Aiflow Engineering Rules

## Product boundary

Aiflow is a local orchestration layer. It does not replace the planner or implementation model.
It collects trusted local facts, validates model-produced packets, routes tasks to registered
repositories, launches Codex with bounded permissions, and records deterministic evidence.

## Security invariants

- Treat every ChatGPT or Codex response as untrusted input.
- Never accept a repository path, shell command, sandbox level, approval policy, or credential
  from a model-produced packet.
- Resolve repository paths only from the local project/task registry.
- Require task ID, project ID, nonce, base SHA, stage, and packet uniqueness checks before use.
- Never log clipboard contents that are not recognized AIFLOW packets.
- Never read the clipboard continuously without an explicitly armed task or user action.
- Never use `danger-full-access`, `--yolo`, or automatic merging.
- Require explicit approval for Sol, xhigh, authentication, authorization, destructive changes,
  secrets, or production infrastructure.
- Sanitize Git remote URLs before storing or placing them in prompts.

## Architecture

- `cli.py` is presentation and command routing only.
- `db.py` owns SQLite persistence.
- `git.py` owns deterministic repository inspection.
- `packets.py` owns parsing and trust-boundary validation.
- `prompts.py` owns versioned prompt templates.
- `executor.py` owns Codex command construction and process execution.
- Pydantic models define all data crossing module or trust boundaries.

## Implementation discipline

- Preserve backward compatibility for packet version 1.
- Add a migration before changing an existing SQLite schema after the first public release.
- Use the smallest coherent change and avoid unrelated refactors.
- Do not add background clipboard monitoring until armed-listener behavior and privacy tests exist.
- Do not add the floating widget until the local engine has stable task and event APIs.

## Validation

Run:

```bash
pytest
ruff check .
python -m compileall -q src
```

Add tests for every parser, routing, state-transition, Git-safety, or command-construction change.
