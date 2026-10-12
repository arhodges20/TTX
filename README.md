# TTX Control Center

A local tool for running **technical tabletop exercises (TTX)** on a Windows
lab host. A facilitator loads a scenario, runs its steps one at a time or all
together, watches live status and an event log, reads facilitator notes and
hunt guidance for each step, and cleans everything up afterwards.

**Benign by design:** every step uses only inert stand-in artifacts (marker
files), and every step has a Cleanup that is verified.

> The project brief lives in [docs/PROJECT-BRIEF.md](docs/PROJECT-BRIEF.md)
> (currently a placeholder until the full brief is added).

## Status

Milestone 1 (control center shell) is in progress.

## Repo layout

```
docs/          Project brief, design decisions
server/        PowerShell backend
ui/            Static web UI (plain HTML/CSS/JS)
modules/       Step modules (one folder per module)
scenarios/     Scenarios (one folder per scenario, scenario.json)
tests/         Syntax and smoke tests
runs/          Session state and logs (gitignored)
```
