# Aiflow Engineering Rules

## Product boundary

Aiflow is a local orchestration layer. It does not replace the planner or implementation model.
It collects trusted local facts, validates model-produced packets, routes work to registered
repositories, launches Codex with bounded permissions, and records deterministic evidence.

The current loop is:

```
ChatGPT Web → Aiflow orchestration → Codex → Aiflow → ChatGPT Web → repeat
```

The clipboard is the bridge between ChatGPT Web and Aiflow. Browser automation and DOM
scraping are not part of the product.

## Surfaces

Aiflow has three surfaces. Only the first two execute anything.

- **Python CLI** (`src/aiflow/`) — the original packet/task/review workflow. Still supported;
  it owns its own SQLite state and runs Codex through `codex exec` in `executor.py`.
- **macOS menu-bar app** (`macos/AiflowMenuBar/`) — the active orchestration surface. Saved
  projects are one-click run targets; the clipboard supplies the prompt. It runs Codex through
  the **Codex App Server**, not `codex exec`, because only the App Server can surface approval
  and clarification requests to a human.
- **VS Code companion** (`vscode/aiflow-vscode/`) — a thin live viewer/controller for the run
  the menu-bar app already owns. It is not a Codex client, not a task engine, and not a
  database.

## Security invariants

- Treat every ChatGPT or Codex response as untrusted input.
- Never accept a repository path, shell command, sandbox level, approval policy, model ID, or
  credential from a model-produced packet — or from the VS Code companion.
- Resolve repository paths only from the local project/task registry or the saved-project store.
- Require task ID, project ID, nonce, base SHA, stage, and packet uniqueness checks before use
  (packet workflow).
- Never log clipboard contents that are not recognized AIFLOW packets.
- Never read the clipboard continuously without an explicitly armed task or user action.
- Never use `danger-full-access`, `--yolo`, `--approve-for-me`, or automatic merging.
- Sanitize Git remote URLs before storing or placing them in prompts.

### Codex App Server invariants (menu-bar surface)

- `sandbox` is always `workspace-write`. Never `danger-full-access`.
- `approvalPolicy` is always `on-request`. Never `never`.
- `approvalsReviewer` is always `"user"`. Never `auto_review` or `guardian_subagent` — those
  route the decision to a subagent and would break the manual-approval promise.
- Approval and clarification requests are always answered by a human. Aiflow never auto-answers,
  and an unrecognized server request is ignored rather than guessed at.
- A request stays pending until the server resolves that exact request ID. A stale resolution
  must never clear a newer request.
- Wire enums use the schema's hyphenated forms; the App Server rejects camelCased variants.
- App Server messages omit the JSON-RPC `jsonrpc` field.

### VS Code companion invariants

- The companion must never launch a second Codex process or session.
- It mirrors and controls the single Aiflow-owned session only.
- The bridge listens on `127.0.0.1` only — never `0.0.0.0` or a LAN interface.
- The bridge accepts only typed, recognized commands. It never accepts repository paths,
  sandbox values, model IDs, prompts, or shell commands from the client.
- A client-supplied request ID may only resolve the request that is currently pending; the
  macOS `WidgetViewModel` state is authoritative.
- Losing the VS Code connection must never affect a running Codex session.
- `file_open` paths must be validated against the active saved repository before being sent.

## Architecture

Python backend:

- `cli.py` is presentation and command routing only.
- `db.py` owns SQLite persistence.
- `git.py` owns deterministic repository inspection.
- `packets.py` owns parsing and trust-boundary validation.
- `prompts.py` owns versioned prompt templates.
- `executor.py` owns `codex exec` command construction and process execution.
- Pydantic models define all data crossing module or trust boundaries.

macOS app:

- `WidgetViewModel` is the single app-lifetime source of truth for the current run. There is
  exactly one instance, owned by `AiflowMenuBarApp`.
- `CodexAppServerClient` owns the App Server process and JSON-RPC framing.
- `CodexProtocol` owns wire payload construction and event decoding.
- `SavedProjectStore` / `ChatProjectMap` own local JSON persistence, not SQLite.
- `AiflowBridgeServer` is transport only — it forwards recognized commands to the view model
  and holds no business logic.

## Implementation discipline

- Preserve backward compatibility for packet version 1.
- Add a migration before changing an existing SQLite schema after the first public release.
- Use the smallest coherent change and avoid unrelated refactors.
- Do not add background clipboard monitoring until armed-listener behavior and privacy tests exist.
- Verify protocol claims against the schema Codex generates
  (`codex app-server generate-json-schema`) and against the running server before relying on them.

## Validation

Python:

```bash
ruff format .
ruff check .
pytest
python -m compileall -q src
```

macOS:

```bash
cd macos/AiflowMenuBar
xcodegen generate
xcodebuild -project AiflowMenuBar.xcodeproj -scheme AiflowMenuBar -destination 'platform=macOS' test
```

VS Code companion:

```bash
cd vscode/aiflow-vscode
npm install && npm run compile && npm test
```

Add tests for every parser, routing, state-transition, Git-safety, protocol, or
command-construction change.
