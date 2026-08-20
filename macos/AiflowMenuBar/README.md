# Aiflow menu bar widget

Copy a prompt → click a project → confirm → Codex runs in that repo.

```
clipboard prompt  →  [ Engineering Foundry ]  →  confirm  →  codex in that repo
```

It knows nothing about Aiflow tasks, plans, reviews, or history — that workflow stays
entirely in the Python CLI.

## The widget

- **Prompt** — a preview of the current clipboard text, with a refresh button. The full
  clipboard text is what gets run, never the truncated preview.
- **Model / Thinking** — Luna/Terra/Sol and Low…XHigh. Defaults Terra + Medium; your
  selection is remembered. Model IDs come from `aiflow models --json`, so they are defined
  once in Python.
- **Projects** — one button per saved repo. The button *is* the run action.
- **+ Add Project** — folder picker; the folder is resolved to its Git root
  (`git -C <path> rev-parse --show-toplevel`) and saved.
- Right-click a project for Map Current Chat / Rename / Reveal in Finder / Remove.

Saved projects live in `~/Library/Application Support/Aiflow/saved-projects.json`.
Chat→project mappings live in `~/Library/Application Support/Aiflow/chat-project-map.json`.
Removing a project only forgets it — the repository on disk is never touched.

## Legacy App Server approvals (fallback)

The details below apply when Aiflow uses its legacy App Server worker. The opt-in official
VS Code worker inherits the official Codex extension's current policy; its menu-bar label says
`Approval: Codex policy` rather than implying that these native sheets control that worker.

Three separate things, none of them automatic:

1. **Starting a run** — clicking a project opens a confirmation sheet. There is no
   "don't ask again".
2. **Codex permission requests** — surfaced as a native Allow Once / Deny sheet. The
   decision applies to that one request only, and the run stays blocked on that exact
   request id until Codex confirms it resolved it.
3. **Codex questions** — a request may carry several questions; each is shown with its
   options or a text field, and every one must be answered before the reply is sent.

The run uses `sandbox: workspace-write` and `approvalPolicy: on-request`. Aiflow never
sends `danger-full-access`, `--approve-for-me`, or any bypass flag.

Runs go through `codex app-server` over newline-delimited JSON-RPC:

```
initialize (capabilities.experimentalApi) → initialized → thread/start (cwd, model,
sandbox, approvalPolicy) → turn/start (threadId, effort, prompt)
```

`initialized` must be sent before any request that follows initialize, and `turn/start`
requires the `threadId` from the `thread/start` response. The thread and turn ids are
retained for the active session so `turn/interrupt` can name them exactly; they are
cleared when the session ends. `turn/completed` carries the turn's own status, so
`completed`, `failed`, and `interrupted` are handled distinctly.

The wire enums are the schema's hyphenated forms (`workspace-write`, `on-request`); the
server rejects camelCased variants.

## Background runs and notifications

The app owns one long-lived run model, not the popover. You can close and reopen the
popover while Codex works. Its menu icon is normal when ready, filled while running,
an exclamation mark while Codex waits for approval/input, a checkmark after completion,
and an xmark after failure.

macOS notification permission is requested only after you start a run. When the popover
is closed, each new approval or question gets its own notification; completion and failure
also notify. Clicking a notification only activates Aiflow — it never approves a request.
Click the attention icon to view the still-pending, exact request and choose Allow Once or
Deny. If notifications are disabled, the attention icon and paused request remain usable.

The app-server request names and response shapes are isolated in `CodexProtocol`. The
handshake and turn lifecycle have been exercised against the installed Codex; the approval
and question requests are decoded from the schema Codex generates but have not yet been
raised by a live run, so those two paths remain unit-tested only.

## Permissions

The first browser URL read prompts for permission to control Google Chrome (and Safari).
Approve it, or the Chat line stays on "No ChatGPT conversation detected". Chat mapping is
only a convenience — every project button works without it.

## VS Code companion bridge

The app listens on `127.0.0.1:47321` (loopback only) from launch, speaking newline-delimited
JSON to the optional VS Code companion in `vscode/aiflow-vscode/`. The companion is a
viewer/controller for *this* run — it never starts Codex and never opens a second session.

Outbound events: `hello`, `snapshot`, `run_started`, `run_status`, `agent_message`,
`approval_requested`, `question_requested`, `run_completed`, `run_failed`, `run_cancelled`,
`file_open`. Inbound commands: `ping`, `cancel`, `approve`, `deny`, `answer_question`.

The connection is authenticated. On connect Aiflow sends only a version `hello`; the client
must then send `{"type":"auth","token":"…"}` before it receives a snapshot or can issue any
command. The token is generated once and stored `0600` at
`~/Library/Application Support/Aiflow/bridge-token`. It is never logged, shown, or included
in an event. A wrong token closes the connection, and authentication is per connection — a
reconnect must authenticate again.

The bridge is transport only. `WidgetViewModel` stays the source of truth:

- A command carries a verb, an optional request id, and answers — never a repository path,
  sandbox, model, prompt, or shell command.
- `approve`/`deny`/`answer_question` are applied only when the id matches the request that is
  currently pending; a stale id resolves nothing.
- `file_open` paths are validated against the active saved repository before being sent.
- Malformed or unknown frames are dropped, and losing the client never affects a running
  Codex session. A reconnecting client is sent a snapshot and rebuilds its UI from it.

## Build, test, regenerate

```sh
xcodegen generate   # after changing project.yml or adding/removing Swift files
xcodebuild -project AiflowMenuBar.xcodeproj -scheme AiflowMenuBar -destination 'platform=macOS' build
xcodebuild -project AiflowMenuBar.xcodeproj -scheme AiflowMenuBar -destination 'platform=macOS' test
```

Codex is found via `AIFLOW_CODEX_PATH`, then `PATH`, then known locations (including the
copy inside `ChatGPT.app`). The `aiflow` CLI is found at `.venv/bin/aiflow` by default
(override with `AIFLOW_CLI_PATH`).
