# TTX Control Center

A local tool for running **technical tabletop exercises (TTX)** on a Windows
lab host. A facilitator loads a scenario, runs its steps one at a time or all
together, watches live status and an event log, reads facilitator notes and
hunt guidance for each step, and cleans everything up afterwards.

**Benign by design:** steps use only inert stand-in artifacts (marker files),
and every step has a Cleanup whose result is verified.

> The project brief lives in [docs/PROJECT-BRIEF.md](docs/PROJECT-BRIEF.md).
> **It is currently a placeholder**: the full brief still needs to be added.

## Status

**Milestone 1: control center shell.** Built; awaiting lab-host testing.

- Lists scenarios from `scenarios/`, loads one, and shows its steps in order.
- Runs a single step or all steps in background jobs. Status and the event log
  update live.
- Shows each step's facilitator notes and hunt guidance.
- Cleanup runs every step's Cleanup in reverse order and verifies it.
- Session state is saved under `runs/`, so Cleanup still works after a restart.
- One scenario: **Persistence via scheduled task**, made of **stub** modules
  that only log and write/remove marker files. No scheduled task is created.

## Requirements

- Windows 10/11 or Windows Server with **Windows PowerShell 5.1** (built in).
- A web browser.
- Admin rights are not required for this milestone.

## Run it

```powershell
cd <path-to-repo>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1
```

Your browser opens <http://localhost:8080/>. Press **Ctrl+C** in the console to
stop the server.

Options: `-Port 8090` uses another port, `-NoBrowser` skips opening the
browser, and `-StepTimeoutSeconds 300` changes the per-step timeout
(default 120).

## How it works

```
Browser (ui/)  --HTTP-->  Start-ControlCenter.ps1
                            server/Server.psm1    HttpListener on localhost, JSON API
                            server/Engine.psm1    scenarios, sessions, queue, saved state
                               | Start-Job (one at a time)
                               v
                            server/StepRunner.ps1 loads one module, runs one operation
                               v
                            modules/<id>/module.ps1   Run / Verify / Cleanup / Hunt
```

- **Artifacts** go to `%ProgramData%\<ArtifactFolder>\<SessionId>\`.
  `ArtifactFolder` is a scenario parameter (default `TTX-Lab`) that you can
  change when loading the scenario.
- **Session state and logs** go to `runs\<SessionId>\state.json` and
  `events.jsonl` (gitignored).
- Only **one session** is active at a time. You can't load another scenario
  until the current session is cleaned up, unless none of its steps ran.
- **Run all** stops at the first failed step. **Cleanup** stops anything in
  progress, then cleans every step in reverse order. A step counts as cleaned
  only if Verify confirms its artifact is gone. The session closes when every
  step is cleaned, and the empty artifact folders are removed.

More detail: [module contract](docs/module-contract.md),
[scenario format](docs/scenario-format.md),
[design decisions](docs/decisions.md).

## Repo layout

```
Start-ControlCenter.ps1   Entry point
docs/                     Project brief, module contract, scenario format, decisions
server/                   PowerShell backend (Engine, Server, StepRunner, shared helpers)
ui/                       Static web UI (plain HTML/CSS/JS, no build step)
modules/                  Step modules (one folder per module; _common = shared helpers)
scenarios/                Scenarios (one folder per scenario, scenario.json)
tests/                    Syntax check and engine smoke test
runs/                     Session state and logs (gitignored)
```

## How to test on the lab host

### Milestone 1: control center shell

Run everything from a normal (non-admin) Windows PowerShell 5.1 console, in
the repo folder.

**0. Get the code**

```powershell
git fetch origin
git checkout claude/wonderful-rubin-xmb6gh
git pull
# Only if you downloaded a ZIP instead of cloning:
Get-ChildItem -Recurse | Unblock-File
```

**1. Static checks.** Expect `All syntax checks passed.`

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Syntax.ps1
```

**2. Engine smoke test.** This runs the whole scenario without the web UI,
simulates a restart, and cleans up. It uses a temp copy of the app and
`C:\ProgramData\TTX-Lab-SmokeTest`, so your real `runs\` folder isn't touched.
Expect every line to read `ok` and `Smoke test passed.` It takes 10–30
seconds.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SmokeTest.ps1
```

**3. Start the control center**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1
```

The browser should open <http://localhost:8080/> showing **connected**
(top right).

**4. Walk through the UI.** Keep a second PowerShell window open for the
checks.

| # | Do this | Expect |
|---|---|---|
| a | Click **Persistence via scheduled task**. Leave `ArtifactFolder` = `TTX-Lab`. Click **Load scenario**. | 3 steps, each `PENDING`, with a STUB tag, facilitator notes, and a "Hunt guidance" toggle. The event log shows "Session … created". |
| b | Click **Run step** on step 1. | The step goes `RUNNING` and then `SUCCEEDED` within a few seconds. The log shows STUB and "Wrote marker file" lines. |
| c | Click **Run all**. | All 3 steps reach `SUCCEEDED`, one after another. |
| d | Second window: `Get-ChildItem C:\ProgramData\TTX-Lab -Recurse` | One `<SessionId>` folder containing `stage-script.marker`, `register-task.marker`, and `task-executes.marker`. |
| e | Second window: `Get-ScheduledTask -TaskName 'TTX-Lab-Updater' -ErrorAction SilentlyContinue` | **Nothing.** The stubs never create a real task. |
| f | Click **Load scenario** again. | A red banner: the session has steps that ran; press Cleanup first. |
| g | **Restart test:** press Ctrl+C in the server console, then start it again (step 3) and refresh the browser. | The same session and statuses come back. The log ends with "Server restarted; restored session …". |
| h | Click **Cleanup** and confirm. | Steps clean up in reverse order (3, 2, 1), each `CLEANED` with "Cleanup check: … absent". The session shows `CLEANED`, and the log ends with "Cleanup complete". |
| i | Second window: `Test-Path C:\ProgramData\TTX-Lab` | `False`. |
| j | **Interrupt test:** Load the scenario, click **Run all**, then click **Cleanup** right away. | Whichever step was running is logged as "Interrupted. Stopped for cleanup." and the rest are logged as "not run". Cleanup still finishes with the session `CLEANED`. If all 3 steps finished before you clicked, try again faster; the result is fine either way. |
| k | Look in `runs\`. | One folder per session, each with `state.json` and `events.jsonl`. |

**5. Report back:**

- The output of steps 1 and 2. Paste any `FAIL` lines in full.
- Any rows in the table above that didn't match, with a screenshot.
- Any red or yellow text in the server console.
- The output of `$PSVersionTable.PSVersion`.

**Troubleshooting**

- *"Could not listen on http://localhost:8080/"*: another program is using
  the port. Start with `-Port 8090`. If it says "Access is denied", try an
  elevated console and report it back.
- *"running scripts is disabled on this system"*: use the
  `-ExecutionPolicy Bypass` command lines above.
- Leftover artifacts can always be inspected under `C:\ProgramData\TTX-Lab\`.
  Marker files are plain JSON text and safe to delete by hand.

## Development notes

This repo is developed in a Linux cloud environment, where the code is
checked with PowerShell 7: `tests/Test-Syntax.ps1`,
`tests/Invoke-SmokeTest.ps1` (with `ProgramData` pointed at a temp folder),
API and UI checks against a running server, and PSScriptAnalyzer's 5.1
compatibility rules. Real Windows PowerShell 5.1 behavior is verified on the
lab host.
