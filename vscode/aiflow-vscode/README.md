# Aiflow Companion (VS Code)

A thin live viewer and controller for the Codex run the **Aiflow macOS menu-bar app**
already owns.

It is not a Codex client. It never starts Codex, never opens a second session, and does not
depend on the official Codex extension. Aiflow remains the source of truth; this extension
renders what Aiflow reports and sends back a small set of verbs.

```
Aiflow menu-bar app  ──(127.0.0.1:47321, newline-delimited JSON)──  VS Code companion
   owns the Codex                                                    views + controls
   App Server session                                                the same run
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
