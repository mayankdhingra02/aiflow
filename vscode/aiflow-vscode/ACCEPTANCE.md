# Manual acceptance test — official Codex VS Code worker

Proves that an Aiflow run is executed by the **official** Codex extension, with the exact
prompt, model, and reasoning effort Aiflow asked for.

Use a disposable repository. Nothing here should be run against real work.

## Setup

```sh
mkdir -p /tmp/aiflow-acceptance && cd /tmp/aiflow-acceptance
git init -q && printf '# scratch\n' > README.md && git add -A && git commit -qm init
```

1. Build and launch the Aiflow menu-bar app.
2. Open `/tmp/aiflow-acceptance` in VS Code.
3. Ensure the official **`openai.chatgpt`** extension is installed and enabled.
4. Launch the Aiflow companion (F5 from `vscode/aiflow-vscode`) and confirm the status bar
   shows **Aiflow: Connected**.
5. In the Aiflow popover, add `/tmp/aiflow-acceptance` as a saved project.

## 1–4. Exact prompt reaches a new official Codex conversation

Copy this prompt:

```
AIFLOW_ACCEPTANCE. Report the current git branch and status. Do not modify any files.
```

Select model **Sol** and thinking **Low**, then click the project button and confirm.

Check:

- [ ] A **new** Codex conversation opens in the official Codex UI (not one you already had).
- [ ] It shows that exact prompt as the user message, character for character.
- [ ] There is **no** TODO wrapper, and no text Aiflow added around your prompt.
- [ ] No second Codex panel or process appears.

## 5–6. Model and effort corroborated by session metadata

Find the session for the conversation id Aiflow reported (shown in the Aiflow status line):

```sh
CONV=<conversation-id>
FILE=$(find ~/.codex/sessions -name "*-$CONV.jsonl" | head -1)
python3 - "$FILE" <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    o = json.loads(line)
    if o.get("type") == "turn_context":
        p = o["payload"]
        print("turn:", p["turn_id"], "cwd:", p.get("cwd"))
        print("approval_policy:", p.get("approval_policy"),
              "approvals_reviewer:", p.get("approvals_reviewer"))
        print("sandbox:", (p.get("sandbox_policy") or {}).get("type"))
EOF
```

Check:

- [ ] Requested model is visible in the official UI's model selector for that thread.
- [ ] `turn_context.cwd` is `/tmp/aiflow-acceptance` (7 — Codex ran in the requested repo).
- [ ] `approval_policy` is `on-request`, `approvals_reviewer` is `user`,
      `sandbox` is `workspace-write` — **not** `danger-full-access`.

## 7–8. Aiflow receives the final answer

- [ ] Codex answers in the official UI.
- [ ] The same final answer appears in Aiflow's status area, and the run shows **Completed**.

## 9. Cancel interrupts the exact official turn

Start a second, longer harmless run:

```
AIFLOW_ACCEPTANCE_LONG. List every file in this repository one at a time and describe each in
detail. Do not modify any files.
```

While it is running, click **Cancel** in Aiflow (or run `Aiflow: Cancel Run` in VS Code).

Check:

- [ ] That conversation's turn stops in the official Codex UI.
- [ ] Any other Codex conversation you have open is untouched.
- [ ] Aiflow shows the run as cancelled.
- [ ] Cancelling again does nothing (idempotent).

## 10. Approvals stay user-mediated

Run a prompt that needs escalation, e.g. writing outside the workspace:

```
AIFLOW_ACCEPTANCE_APPROVAL. Create a file at ~/aiflow-acceptance-probe.txt containing "test".
```

Check:

- [ ] The official Codex UI asks **you** for approval.
- [ ] Aiflow does not answer it automatically.
- [ ] Denying it prevents the file from being created:
      `ls ~/aiflow-acceptance-probe.txt` → no such file.

## 11. The legacy worker did not also start

While a run is in flight:

```sh
ps aux | grep -c "[c]odex app-server"     # started by Aiflow? see below
lsof -nP -iTCP:47321 | tail -2            # the companion bridge is connected
```

Check:

- [ ] Aiflow itself did **not** spawn a `codex app-server` child — only the official
      extension's own Codex process is running.
- [ ] Aiflow's status shows the official worker served the run.

## Cleanup

```sh
rm -rf /tmp/aiflow-acceptance ~/aiflow-acceptance-probe.txt
```
