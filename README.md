# Aiflow

Aiflow is a local macOS orchestration bridge for a cost-efficient development workflow:

1. ChatGPT Web with **Sol** plans and reviews.
2. Aiflow validates the copied structured packet and routes it to the correct local project.
3. Codex CLI with **Luna**, **Terra**, or **Sol** implements the approved plan.
4. Local Git and validation commands provide deterministic evidence.

This Phase 1 repository implements the safe local core. It does not scrape ChatGPT and does not need Codex usage until you explicitly run a task with `--execute`.

## Phase 1 capabilities

- Register any local Git project.
- Create a task tied to the exact project, branch, and base commit.
- Generate and copy a standardized Sol planning prompt.
- Parse a copied `AIFLOW_PACKET_V1` response.
- Validate task ID, project ID, nonce, base commit, packet uniqueness, model role, reasoning effort, and risk fields.
- Save the approved plan and implementation prompt.
- Preview the exact future `codex exec` command without consuming usage.
- Execute Codex only after an explicit `--execute` choice.

## Requirements

- macOS
- Python 3.11 or newer
- Git
- `pbcopy` and `pbpaste` (included with macOS)
- Codex CLI only when you are ready to execute implementation

## Install for development

```bash
cd /path/to/aiflow
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

Run the checks:

```bash
pytest
ruff check .
```

## First use

### 1. Check your machine

```bash
aiflow doctor
```

Codex may show as missing or unavailable right now. That is fine for planning and packet import.

### 2. Register a project

From any Git repository:

```bash
cd ~/Desktop/Engineeringfoundry
aiflow register
```

List all registered projects:

```bash
aiflow projects
```

### 3. Start a planning task

```bash
aiflow start "Add the Interview Playbook page using the completed research"
```

Aiflow records the project and base commit, creates task files under:

```text
~/Library/Application Support/Aiflow/tasks/<task-id>/
```

It also copies the Sol planning prompt to the macOS clipboard.

### 4. Use ChatGPT Web

- Paste the prompt into ChatGPT Web with Sol.
- Let Sol inspect the connected GitHub repository.
- Copy the complete response containing `AIFLOW_PACKET_V1`.

Then import it:

```bash
aiflow import-packet --clipboard
```

### 5. Preview the Codex implementation

```bash
aiflow run <task-id> --dry-run
```

This prints the exact repository, model, reasoning level, sandbox, prompt, and output path. It does **not** call Codex or consume usage.

When usage is available and the task is safe to run:

```bash
aiflow run <task-id> --execute
```

Aiflow asks for confirmation before launching Codex CLI.

## Packet format

Sol returns a packet shaped like this:

````text
AIFLOW_PACKET_V1
```json
{
  "packet_version": 1,
  "packet_id": "unique-packet-id",
  "project_id": "engineering-foundry",
  "task_id": "engineering-foundry-abcdef123456",
  "nonce": "generated-by-aiflow",
  "stage": "implementation_plan",
  "base_sha": "exact-git-sha",
  "execution": {
    "model_role": "terra",
    "reasoning_effort": "high"
  },
  "risk": {
    "level": "medium",
    "touches_authentication": false,
    "touches_authorization": false,
    "touches_database": false,
    "destructive_change": false,
    "touches_secrets": false,
    "touches_production_infrastructure": false
  },
  "requires_human_approval_before_execution": false
}
```
---AIFLOW_BODY---
# Implementation Plan

The complete file-by-file plan goes here.
AIFLOW_PACKET_END
````

## Data location

Aiflow stores local state at:

```text
~/Library/Application Support/Aiflow/
```

Set `AIFLOW_HOME` to override this path, which is useful for tests or portable installations.

## Safety properties in Phase 1

- A model cannot choose an arbitrary local directory.
- The trusted task ID resolves to a locally registered repository.
- The packet must contain the one-time nonce created by Aiflow.
- The packet must match the exact base commit.
- Duplicate packet IDs are rejected.
- Only Luna, Terra, and Sol roles are accepted.
- Only low, medium, high, and xhigh reasoning are accepted.
- `workspace-write` is fixed by Aiflow.
- Execution is a dry run unless `--execute` is explicitly selected.
- Sol and xhigh recommendations are surfaced for human approval.

## Next phases

1. Deterministic project validation commands and captured logs.
2. Review-packet generation from the base-to-head Git diff.
3. One bounded correction pass.
4. Armed clipboard helper.
5. Native floating macOS edge widget.
6. Optional VS Code and Chrome convenience interfaces.
