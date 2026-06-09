# Iteration Seed Template

## Goal

Describe the first concrete outcome Codex should deliver for this project.

## Context

- Project directory: `projects/<project-name>`
- Runtime directory: `runs/<project-name>`
- Generated iteration docs directory: `docs/iterations`

## Tasks

- [ ] Inspect the project README, build files, test configuration, and git status.
- [ ] Identify the smallest useful implementation or verification slice.
- [ ] Make the change or run the setup needed for that slice.
- [ ] Run the most relevant verification command.
- [ ] Update this document with completed work, verification results, blockers, and the next iteration direction.
- [ ] Create the next iteration document under `docs/iterations/`.
- [ ] Write the next document path to `runs/<project-name>/state/current_doc`.

## Verification

List the command(s) that prove this iteration worked.

## Stop Conditions

- Stop only if the task is complete, the requested proof has passed, or a blocker is documented with a smaller next-step document.
- Do not wait for human approval unless the environment prevents meaningful progress.

## Risks

- Note any commands that may be long running.
- Note any services, ports, credentials, or external dependencies involved.
