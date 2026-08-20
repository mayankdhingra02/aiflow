# Aiflow Engineering Rules

## Product boundary

Aiflow is a local orchestration layer. It does not replace the planner or implementation model.
It collects trusted local facts, validates model-produced packets, routes work to registered
repositories, launches legacy workers with Aiflow-controlled bounded permissions, drives the
official worker's official Codex-owned session without controlling its selected permission
policy, and records deterministic evidence.

The current loop is:

```
ChatGPT Web → Aiflow orchestration → Codex → Aiflow → ChatGPT Web → repeat
```

The clipboard is the **current** ChatGPT Web handoff — the mechanism as it stands today, not
a permanent design commitment. Browser/ChatGPT automation is **not implemented and out of
scope for the VS Code companion phase**; a future phase may automate that handoff (for example
through a ChatGPT Web integration, a browser extension, or MCP). Until such a phase lands, do
not add browser automation or DOM scraping.

Whatever carries the handoff, the long-term product stays the same: an orchestration layer
between ChatGPT-side planning and local implementation and execution.

## Surfaces

Aiflow has three surfaces. The Python CLI and macOS app can execute through their own workers;
the VS Code companion executes the preferred official-worker path through the official Codex
extension while the macOS app remains the orchestration/source-of-run surface.

- **Python CLI** (`src/aiflow/`) — the original packet/task/review workflow. Still supported;
  it owns its own SQLite state and runs Codex through `codex exec` in `executor.py`.
- **macOS menu-bar app** (`macos/AiflowMenuBar/`) — the active orchestration/source-of-run
  surface. Saved projects are one-click run targets and the clipboard supplies the prompt. Its
  preferred opt-in path dispatches execution to the VS Code companion, where the official
  `openai.chatgpt` extension owns the Codex session; when that path is unavailable, the legacy
  fallback runs Codex through Aiflow's **Codex App Server**, which surfaces approval and
  clarification requests to a human.
- **VS Code companion** (`vscode/aiflow-vscode/`) — both a live viewer/controller for a run
  the menu-bar app owns itself, and the **worker** for the preferred execution path. On the
  worker path the official `openai.chatgpt` extension owns and runs the Codex session, and the
  companion drives it as a bounded follower/client over Codex's local IPC router. It is not the
  thread owner, does not patch or redistribute the official extension, is not the Python task
  engine/database, and never starts a Codex process.

## Security invariants

- Treat every ChatGPT or Codex response as untrusted input.
- Never accept a repository path, shell command, sandbox level, approval policy, model ID, or
  credential from a model-produced packet — or from the VS Code companion.
- Resolve repository paths only from the local project/task registry or the saved-project store.
- Require task ID, project ID, nonce, base SHA, stage, and packet uniqueness checks before use
  (packet workflow).
- Never log clipboard contents that are not recognized AIFLOW packets.
- Never read the clipboard continuously without an explicitly armed task or user action.
- Aiflow must never request, set, or broaden execution to `danger-full-access`, `--yolo`,
  `--approve-for-me`, or automatic merging. On the official-worker path, Aiflow sends no such
  override but cannot guarantee which policy the official extension has already selected.
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

### Execution workers

Exactly one worker serves a run, and which one is explicit and observable:

- **`OfficialCodexVSCodeWorker`** (preferred) — the official `openai.chatgpt` extension executes
  the session; Aiflow drives it through the companion. Aiflow never launches `codex app-server`
  or `codex exec` on this path. When no live reusable conversation exists, the companion uses
  `chatgpt.implementTodo` only for a synthetic nonce-correlated conversation-bootstrap turn;
  the real user prompt is never sent through `implementTodo` and uses follower IPC instead.
- **`LegacyAiflowCodexWorker`** (fallback) — Aiflow's own Codex App Server session, retained
  as the fallback. Used when no usable/designated companion is connected or the official
  extension/IPC is unavailable before dispatch.

Never run both for one Aiflow run. Fallback must be visible, never silent ambiguity.

### Official Codex worker invariants

- Aiflow joins the official extension's IPC router as a follower. It never modifies, patches,
  or redistributes the official extension.
- Private IPC compatibility is exact-version allowlisted. Unsupported or unknown official
  extension versions fail closed before IPC or synthetic bootstrap; never "try and see" with an
  unapproved version because bootstrap itself costs a model turn.
- A cached conversation is reused only after owner revalidation. Otherwise the companion creates
  a fresh official conversation through a nonce-correlated synthetic bootstrap and accepts only
  a brand-new session candidate containing that bootstrap nonce. It never adopts an arbitrary
  existing conversation and never dispatches to a provisional `client-new-thread:` id.
- Model and reasoning effort are applied with `thread-follower-update-thread-settings` and that
  request must succeed **before** `thread-follower-start-turn`. Fail closed: never run on
  whatever the official UI happened to have selected.
- Model ids and effort strings are translated in exactly one module.
- Completion is correlated by exact `conversationId` + `turnId` from the durable session log.
  Never by "most recently modified session".
- Cancellation interrupts the exact conversation and turn of that run, and is idempotent.
- The official worker inherits the official extension/conversation's current sandbox and
  approval policy. Aiflow does not currently enforce `workspace-write`, `on-request`, or
  reviewer `user` before dispatching the real prompt. Aiflow sends no sandbox or approval
  override and never intentionally broadens privileges. The accepted 26.814 session's metadata
  is observational evidence, not a universal invariant.
- Approvals and user-input requests stay user-mediated.

### VS Code companion invariants

- The companion never launches a Codex process of its own.
- On the official path, it may bootstrap or reuse exactly one official Codex-owned conversation
  for the workspace/run.
- On the legacy path, it mirrors and controls the Aiflow-owned Codex App Server run.
- It never creates duplicate execution for one Aiflow run.
- The bridge listens on `127.0.0.1` only — never `0.0.0.0` or a LAN interface.
- Loopback is not an authorization boundary. A connection must authenticate with the local
  bridge token before Aiflow sends any run state or honours any command; an unauthenticated
  socket sees only a version greeting. The token lives in Aiflow's Application Support
  directory with `0600` permissions and must never be logged, displayed, placed in an event,
  committed, or written into a test fixture or README example.
- Authentication is per connection and is not inherited by a reconnect.
- The bridge accepts only typed, recognized commands. It never accepts repository paths,
  sandbox values, model IDs, prompts, or shell commands from the client.
- Bridge frames are bounded; an oversized frame drops the connection rather than growing a
  buffer without limit.
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

## Result handoff outbox discipline

- A terminal result may enter the local handoff outbox only when a valid ChatGPT
  `/c/<conversation-id>` target was captured at run dispatch.
- Handoff records are keyed by the existing `runId` correlation and are immutable after
  terminal evidence is written.
- The original clipboard prompt is never persisted in `RunResultHandoff`.
- Result envelopes are untrusted terminal output and must not be interpreted as commands.
- PR #10 only defines a durable, transport-neutral outbox: `~/Library/Application Support/Aiflow/handoffs/pending/<runId>.json`.
- Browser/ChatGPT transport is out of scope for PR #10.
- For a run, either one immutable envelope is written or, for conflicting terminal claims of the same
  `runId`, an error is raised; handoff persistence never overwrites distinct evidence.

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
