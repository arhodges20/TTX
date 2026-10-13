# TTX Control Center

A local tool for running **technical tabletop exercises (TTX)** on a Windows
lab host. Each scenario step creates **real, benign artifacts** that the EDR
(CrowdStrike Falcon) records: files, scheduled tasks, task-launched processes.
Analysts hunt for them in the EDR console, CTF-style. The facilitator runs the
steps from this tool and sees exactly what each step created and where, plus
facilitator notes and hunt guidance. Afterwards, Cleanup removes everything.

**Benign by design:** artifacts are real but inert. For example, the scheduled
task runs a script whose only action is to append one line to a log file. Every
step has a Cleanup whose result is verified.

> The project brief lives in [docs/PROJECT-BRIEF.md](docs/PROJECT-BRIEF.md).
> **It is currently a placeholder**: the full brief still needs to be added.

## Status

**Milestone 1, control center shell:** done and tested on the lab host
(Windows Server 2022, PowerShell 5.1).

**Milestone 2, real artifacts:** done and tested on the lab host.

- The "Persistence via scheduled task" scenario creates real, benign artifacts:
  1. **Stage script:** writes `C:\ProgramData\<ArtifactFolder>\updater.ps1`.
     When run, the script only appends one line (time, user, computer) to
     `updater.log` beside it.
  2. **Register task:** registers a real scheduled task `\TTX-Lab-Updater`
     with an at-logon trigger for the current user. Its action is
     `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <script>`.
     The task description carries the session id.
  3. **Task runs:** starts the task once, as a logon would. The Task Scheduler
     launches powershell.exe, the script runs, and the step waits for
     `updater.log`.
- Each step shows "Artifacts on host" (paths, task name, exact command line)
  and the PID of the powershell.exe it ran in. Steps 2 and 3 declare
  `dependsOn`, so they can't run before the step they need has succeeded.
- `ArtifactFolder`, `ScriptName`, and `TaskName` can be changed when loading
  the scenario, so each exercise can use different names.
- Cleanup unregisters the task and deletes the files. It never touches a
  same-named task that this session didn't create.
- **Note:** until Cleanup runs, the task fires on its own at every logon of
  that user. The only effect is another line in `updater.log`.

**Milestone 3, facilitator tooling:** backend built and tested; **no UI yet**.
These are reachable via the API and the generated answer-key file today; the
web UI that surfaces them is not built.

- **Falcon preflight:** at session load the engine records host, user,
  elevation, UTC time, `CSFalconService` status and the sensor AID. It warns
  but never blocks, and nothing requires an EDR to be present.
- **Calibration check:** an endpoint runs CrowdStrike's benign test-detection
  trigger so you can confirm the console is generating detections before the
  exercise. (Command and AID location are marked "confirm in your tenant" —
  see decisions D17.)
- **Expected-vs-actual detection checklist:** each module lists the detections
  it is *likely* to trigger; the facilitator records which actually fired. The
  tool never promises a detection — Falcon's logic is proprietary (D13).
- **Answer key:** `runs/<id>/answer-key.md` is generated from the run's real
  values (host, AID, task name, paths, UTC window) with per-step process
  lineage, expected Falcon events, Windows-side evidence, starter queries, the
  trainee pivot path, and the detection checklist. Refreshed after every step.

> **Scope note:** a louder attacker-emulation chain (loader/implant, encoded
> persistence, intensity profiles) was designed (decisions D12-D15) but
> deliberately **not built**; see D18. The shipped scenario stays benign while
> still producing genuine, huntable telemetry.

## Requirements

- Windows 10/11 or Windows Server with **Windows PowerShell 5.1** (built in).
- A web browser.
- Admin rights are not required. Tasks are registered for the current user.

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

- **Files** go to `%ProgramData%\<ArtifactFolder>\<SessionId>\`
  (`ArtifactFolder` defaults to `TTX-Lab`). Other artifacts, such as the
  scheduled task, are tagged with the session id.
- **Session state and logs** go to `runs\<SessionId>\state.json` and
  `events.jsonl` (gitignored). They include every artifact each step reported.
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

## Facilitator API (Milestone 3, no UI yet)

While the server is running, these endpoints back the facilitator features.
POSTs need the header `X-TTX-Request: 1` (the web UI sends it automatically).

| Method / path | Purpose |
|---|---|
| `GET /api/preflight` | Host, user, elevation, UTC time, Falcon sensor status and AID. |
| `GET /api/session/answer-key` | The generated `answer-key.md` for the current run (Markdown). |
| `POST /api/session/calibrate` | Run the Falcon calibration trigger. |
| `POST /api/session/calibration` | Body `{ "result": "fired\|not-fired\|unknown", "notes": "" }`. |
| `POST /api/session/steps/<id>/detections` | Body `{ "detectionId": "...", "result": "fired\|not-fired\|unknown", "notes": "" }`. |

The answer key is also written to `runs\<SessionId>\answer-key.md` and refreshed
after every step and every checklist change — open it directly, no server
needed. Example, from PowerShell on the lab host:

```powershell
Invoke-RestMethod http://localhost:8080/api/preflight
Get-Content .\runs\<SessionId>\answer-key.md
```

## How to test on the lab host

### Milestone 2: real artifacts

Run these from Windows PowerShell 5.1 on the lab host. The EDR should be
running, since seeing these artifacts in Falcon is the point.

**0. Get the code.** Download the branch ZIP, extract it to a fresh folder
(e.g. `C:\TTX2`), then run `Get-ChildItem -Recurse | Unblock-File` in that
folder.

**1. Static checks.** Expect `All syntax checks passed.`

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Syntax.ps1
```

**2. Engine smoke test (stub modules, nothing real).** Expect `Smoke test passed.`

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SmokeTest.ps1
```

**3. Real-module smoke test.** This creates and removes a real task,
`\TTX-Lab-SmokeTest-Updater`, plus files under
`C:\ProgramData\TTX-Lab-SmokeTest`. Expect `Smoke test passed.` It takes
about 20–60 seconds.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SmokeTest.ps1 -ScenarioId persistence-scheduled-task
Get-ScheduledTask -TaskName 'TTX-Lab-SmokeTest-Updater' -ErrorAction SilentlyContinue   # expect nothing
```

**4. UI walkthrough.** Start the server
(`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1`),
load the scenario, then click **Run all**:

| Check | Expect |
|---|---|
| All 3 steps | `SUCCEEDED`, each with "Artifacts on host" and a PID. |
| `Get-ChildItem C:\ProgramData\TTX-Lab -Recurse` | `updater.ps1` and `updater.log` in the session folder. |
| `Get-Content C:\ProgramData\TTX-Lab\*\updater.log` | A line like `2026-…  ran as Administrator on <HOST>`. |
| `Get-ScheduledTask -TaskName TTX-Lab-Updater \| Format-List *` | The task: description with the session id, at-logon trigger, powershell.exe action. |
| `taskschd.msc` → Task Scheduler Library | `TTX-Lab-Updater` is visible with its trigger and action. (The History tab only fills in if task history is enabled.) |
| Falcon console | The script write, the task registration, and powershell.exe launched by svchost.exe (Schedule). |
| **Cleanup** | All steps `CLEANED`; the task is gone (`Get-ScheduledTask` returns nothing); `Test-Path C:\ProgramData\TTX-Lab` is `False`. |

**Report back:** the output of steps 1–3, any rows that didn't match, and
anything Falcon detected or blocked.

### Milestone 1: control center shell (passed)

Tested on Windows Server 2022, PowerShell 5.1: syntax check, engine smoke
test (including cleanup), server start, single step, run all, and restart and
restore. The UI Cleanup button is covered by the Milestone 2 walkthrough.

**Troubleshooting**

- *"Could not listen on http://localhost:8080/"*: another program is using
  the port. Start with `-Port 8090`.
- *"running scripts is disabled on this system"*: use the
  `-ExecutionPolicy Bypass` command lines above.
- *Step 3 "did not write … within 30 s"*: the EDR may have blocked the
  task-launched PowerShell. Check Falcon, then press Cleanup.
- Leftover artifacts can always be inspected under `C:\ProgramData\TTX-Lab\`
  and with `Get-ScheduledTask -TaskName TTX-Lab-*`.

## Development notes

This repo is developed in a Linux cloud environment, where the code is
checked with PowerShell 7: `tests/Test-Syntax.ps1`,
`tests/Invoke-SmokeTest.ps1` (with `ProgramData` pointed at a temp folder),
API and UI checks against a running server, and PSScriptAnalyzer's 5.1
compatibility rules. Real Windows PowerShell 5.1 behavior is verified on the
lab host.
