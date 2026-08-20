# Aiflow Companion (VS Code)

Two roles, over one authenticated local bridge:

1. **Worker (preferred path).** The macOS app asks the companion to execute a run, and the
   companion drives the **official OpenAI Codex extension** (`openai.chatgpt`) to do it. The
   session runs and is visible in the official Codex UI.
2. **Viewer/controller (legacy path).** When the app runs Codex itself, the companion mirrors
   and controls that run.

The companion never starts a Codex process, never opens a second session, and never modifies
the official extension. It uses `chatgpt.implementTodo` only once with a synthetic, Aiflow-owned
temporary file to bootstrap an empty official thread; the user's prompt is submitted afterwards
through Codex's local client-coordination IPC as a *follower*.

```
Aiflow menu-bar app  ──(127.0.0.1:47321, newline-delimited JSON)──  VS Code companion
                                                                      │
                                                    official Codex local IPC router
                                                                      │
                                                     openai.chatgpt extension runs Codex
```

## What it shows

An **Aiflow** container in the Activity Bar with a *Current Run* tree:

- Connection — Connected / Disconnected
- Status — Ready, Running, Waiting for approval, Waiting for input, Cancelling, Completed, Failed
- Project, Model / effort
- Latest agent message
- The pending approval or question, when there is one

Plus a status-bar item: `Aiflow: Connected` / `Running` / `Waiting for approval` / `Disconnected`.

## Commands

| Command | Purpose |
| --- | --- |
| `Aiflow: Reconnect` | Drop the socket and retry immediately |
| `Aiflow: Cancel Run` | Ask Aiflow to interrupt the active turn |
| `Aiflow: Allow Once` | Approve the current pending request |
| `Aiflow: Deny` | Deny the current pending request |
| `Aiflow: Answer Codex Question` | Answer every question in the pending request |

Approve/Deny/Answer always carry the exact request id the bridge reported. Aiflow ignores a
command whose id does not match what is currently pending, so a stale click cannot resolve a
newer request.

## Official Codex worker

> **Status: opt-in, off by default.** Enable with `aiflow.officialWorker.enabled`.
> Low-level fresh-thread bootstrap and follower execution are proven; final app-level acceptance
> is still pending.

Requires the official **`openai.chatgpt`** extension to be installed. The companion activates
it if needed; it never bundles or redistributes it.

For each run the companion:

1. joins the official extension's local IPC router as an additional client,
2. snapshots session-file identities, then uses one synthetic `implementTodo` turn with an
   Aiflow-owned temporary file and unique nonce to mint a **new** Codex conversation,
3. correlates only a new or changed session containing that nonce — an already-open conversation
   is never used,
4. verifies the bootstrap turn completed and recorded the requested workspace,
5. applies the requested model and reasoning effort and **requires that to succeed**,
6. submits the exact Aiflow prompt verbatim through follower IPC, then
7. watches that one conversation's session log for that one turn's completion.

The bootstrap TODO wrapper exists only on the synthetic first turn. The user's prompt never
reaches `chatgpt.implementTodo`. Bootstrap is intentionally performed once for the newly-created
conversation; future turns should reuse its conversation id. The current companion retains the
id for the active worker/run lifetime and does not yet add cross-run persistence.

Model/effort translation lives in one module (`src/codexIpc/models.ts`); nothing else
hard-codes a Codex model id.

### Permissions

Aiflow sends no sandbox or approval overrides. The run inherits the official extension's own
safe defaults (workspace-write, approvals on request, reviewed by you), and approval and
question prompts stay in the official Codex UI where you answer them. A run can never become
`danger-full-access` because another Codex thread was configured differently.

### Wire protocol

Requests use the router's envelope:

```
{ type: "request", requestId, sourceClientId, version, method, params,
  targetClientId?, timeoutMs? }
```

`targetClientId` is an **envelope** field, never part of a follower's `params`. Responses are
matched by `requestId` and carry `resultType`; `thread-owner-discovery` answers with an empty
`result` and names the owner in `handledByClientId`.

Request versions follow the official extension's own table: owner-discovery 1, start-turn 1,
update-thread-settings 1, interrupt-turn 4 — dropping to 3 when no `expectedTurnId` is known,
exactly as the extension's own version function does. Cancellation sends
`{ conversationId, mode: "user-stop", expectedTurnId }`.

### Bootstrap note

An empty `chatgpt.newCodexPanel` or `chatgpt.newChat` does not announce a routable conversation,
and the follower router exposes no explicit thread-creation request. The companion therefore
uses the narrow synthetic bootstrap above. It does not automate the UI and does not send the
real Aiflow prompt through `implementTodo`.

| Route | Result |
| --- | --- |
| `chatgpt.newCodexPanel` | executes; announces only `client-status-changed` with **no** conversation id |
| `chatgpt.newChat` | same — no conversation id |
| `thread-stream-following-status-requested` | `resultType: error`, `no-client-found` |
| router method table | contains **no** thread-creation request; every `thread-follower-*` op addresses an existing `conversationId` |

The low-level bootstrap and exact follower turn have been exercised against the official
extension. The official worker remains **off by default** until the complete menu-bar app →
companion acceptance is reviewed. The legacy Aiflow worker remains available as the explicit
fallback.

### Fallback

If the official extension is missing, its IPC is unreachable, or a fresh conversation cannot be
correlated, the worker fails with a typed error and Aiflow falls back to running Codex itself.
The fallback is explicit — the macOS app records which worker served each run.

## Troubleshooting

- **"official Codex is unavailable"** — install/enable `openai.chatgpt`, then retry. Aiflow
  reads the router socket at `~/.codex/ipc/ipc.sock`
  (override with `CODEX_IPC_SOCKET`).
- **The run never starts** — check that the official extension is active and that its session
  directory is writable. The companion must be able to create and remove its temporary bootstrap
  file under the OS temp directory.
- **Completion never arrives** — sessions are read from `~/.codex/sessions`
  (override with `CODEX_HOME`).

## Safety boundaries

- Connects only to `127.0.0.1:47321`.
- **Authenticates before anything else.** Loopback alone is not an authorization boundary, so
  the extension reads Aiflow's local token from
  `~/Library/Application Support/Aiflow/bridge-token` and sends it as an `auth` command the
  moment the socket opens — including after every reconnect. Until that succeeds Aiflow sends
  no run state and accepts no commands. If the token file is missing (Aiflow has never run),
  the extension says so and stays idle rather than retrying blindly. The token is never
  logged or shown.
- Inbound frames are capped at 1 MiB; an oversized frame drops the connection.
- Outbound commands carry a verb, an optional request id, and answers — there is no field for
  a repository path, sandbox, model, prompt, or shell command.
- `file_open` paths are validated against the active saved repository **on the Aiflow side**
  before being sent; the extension opens them with `vscode.workspace.openTextDocument`, never
  by shelling out to `code`.
- Losing this connection never affects a running Codex session. Reconnecting replays a
  snapshot so the view rebuilds without restarting anything.
- Nothing is auto-approved.

## Develop and run

```sh
npm install
npm run compile
npm test          # unit tests: protocol framing/parsing + bridge client
```

Then press **F5** in VS Code to launch an Extension Development Host. Start the Aiflow
menu-bar app first, or use `Aiflow: Reconnect` once it is running.

`npm test` covers `protocol.ts` and `bridgeClient.ts`, which have no `vscode` dependency.
`extension.ts` and `aiflowView.ts` import the `vscode` module and can only be exercised
inside an Extension Development Host, so they are verified manually rather than by unit test.
