# Codex Continuous Framework

Codex Continuous Framework is a small shell-based wrapper for running the
installed `codex` CLI in a persistent autonomous development loop on an isolated
server.

It does not modify Codex itself. It gives Codex a project directory, a current
iteration document, runtime state directories, and a prompt contract that tells
Codex how to finish one slice, write the next document, and continue.

## Layout

```text
codex-continuous-framework/
  bin/
    codex-continuous-runner.sh   # Main loop runner
  config/
    runner.env.example           # Optional environment template
    runner.unrestricted.env.example
  docs/
    iterations/                  # Generated iteration docs; ignored except .gitkeep
    templates/                   # Tracked templates for seed docs
  projects/                      # Active projects; ignored except .gitkeep
  runs/                          # Runtime prompts/logs/state; ignored except .gitkeep
```

`projects/`, `runs/`, and `docs/iterations/` are intentionally empty in git.
They are working directories on the server and may contain large generated
artifacts, checked-out projects, logs, toolchains, prompts, and generated
documents.

## Quick Start

Put a project under `projects/`:

```bash
cd codex-continuous-framework
git clone <repo-url> projects/my-app
```

Create the first iteration doc:

```bash
cp docs/templates/seed-template.md docs/iterations/my-app-seed.md
```

Run forever:

```bash
CODEX_MAX_ROUNDS=0 \
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

Run under `tmux` on Ubuntu:

```bash
tmux new -s codex-my-app
cd /path/to/codex-continuous-framework
source config/runner.env
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

Detach with `Ctrl-b d`. Reattach with:

```bash
tmux attach -t codex-my-app
```

## Full-Permission Sandbox Mode

For a disposable Ubuntu server that is already your sandbox:

```bash
cp config/runner.unrestricted.env.example config/runner.env
source config/runner.env
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

This mode runs Codex with:

```bash
codex --search exec --dangerously-bypass-approvals-and-sandbox ...
```

It also injects prompt authorization for:

- `sudo` commands
- web search and network access
- dependency and system package installation
- writing and running helper scripts
- starting dev servers or background services
- monitoring ports, health checks, logs, and process state

Use this mode only inside a disposable VM/container or another externally
isolated environment.

## Runtime State

For project `my-app`, the runner writes:

```text
runs/my-app/
  logs/       # codex --json output and last assistant messages
  prompts/    # prompt sent to each round
  state/
    current_doc
    round
    session_started
```

Codex must write the next iteration document path into:

```text
runs/my-app/state/current_doc
```

Relative paths in `current_doc` are resolved against `docs/iterations/`.

## Important Environment Controls

| Variable | Meaning |
| --- | --- |
| `CODEX_BIN` | Codex executable, default `codex`. |
| `CODEX_MODEL` | Optional model passed with `-m`. |
| `CODEX_PROFILE` | Optional Codex config profile passed with `-p`. |
| `CODEX_PROJECTS_DIR` | Project root directory. Defaults to `projects/`. |
| `CODEX_DOCS_DIR` | Iteration docs directory. Defaults to `docs/iterations/`. |
| `CODEX_RUNS_DIR` | Runtime directory. Defaults to `runs/`. |
| `CODEX_RUN_NAME` | Override the run directory name. |
| `CODEX_MAX_ROUNDS` | `0` means forever. |
| `CODEX_SLEEP_SECONDS` | Delay between rounds. |
| `CODEX_RESET_LOOP` | Set to `1` to ignore saved state and restart from the seed doc. |
| `CODEX_UNRESTRICTED` | Set to `1` for isolated-server maximum-permission mode. |
| `CODEX_DANGER_FULL_ACCESS` | Pass Codex `--dangerously-bypass-approvals-and-sandbox`. |
| `CODEX_ENABLE_SEARCH` | Pass top-level `--search`. |
| `CODEX_ALLOW_SUDO` | Tell Codex sudo is allowed in the prompt contract. |
| `CODEX_ALLOW_INSTALL` | Tell Codex installs are allowed in the prompt contract. |
| `CODEX_ALLOW_LONG_RUNNING` | Tell Codex background services are allowed in the prompt contract. |
| `CODEX_ALLOW_SCRIPTING` | Tell Codex helper scripts are allowed in the prompt contract. |

To restart from the seed doc instead of resuming saved runner state:

```bash
CODEX_RESET_LOOP=1 ./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

## Git Hygiene

The repository tracks only the framework itself:

- `bin/`
- `config/*.example`
- `docs/templates/`
- empty directory markers for `docs/iterations/`, `projects/`, and `runs/`

The following are intentionally ignored:

- checked-out projects under `projects/`
- generated iteration documents under `docs/iterations/`
- prompts, logs, state, scripts, monitors, toolchains, and caches under `runs/`
- local operator config such as `config/runner.env`

This keeps the framework portable and prevents a running automation session from
polluting the framework repository.
