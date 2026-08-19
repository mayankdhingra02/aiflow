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

## Approvals are always manual

Three separate things, none of them automatic:

1. **Starting a run** — clicking a project opens a confirmation sheet. There is no
   "don't ask again".
2. **Codex permission requests** — surfaced as a native Allow Once / Deny sheet. The
   decision applies to that one request only.
3. **Codex questions** — surfaced with a text field so you can answer.

The run uses `sandbox: workspace-write` and `approvalPolicy: on-request`. Aiflow never
sends `danger-full-access`, `--approve-for-me`, or any bypass flag.

Because `codex exec` is non-interactive, runs use `codex app-server` over newline-delimited
JSON-RPC:
`initialize` → `thread/start` (cwd, model, sandbox, approvalPolicy) → `turn/start`
(threadId, effort, prompt).

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

The app-server request names and response shapes are isolated in `CodexProtocol` and covered
by mocks. They still require end-to-end verification against the installed Codex version
before claiming live approval/input support.

## Permissions

The first browser URL read prompts for permission to control Google Chrome (and Safari).
Approve it, or the Chat line stays on "No ChatGPT conversation detected". Chat mapping is
only a convenience — every project button works without it.

## Build, test, regenerate

```sh
xcodegen generate   # after changing project.yml or adding/removing Swift files
xcodebuild -project AiflowMenuBar.xcodeproj -scheme AiflowMenuBar -destination 'platform=macOS' build
xcodebuild -project AiflowMenuBar.xcodeproj -scheme AiflowMenuBar -destination 'platform=macOS' test
```

Codex is found via `AIFLOW_CODEX_PATH`, then `PATH`, then known locations (including the
copy inside `ChatGPT.app`). The `aiflow` CLI is found at `.venv/bin/aiflow` by default
(override with `AIFLOW_CLI_PATH`).
