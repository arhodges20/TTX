# TTX Control Center

A local tool for running **technical tabletop exercises (TTX)** on a Windows
lab host. Each scenario step runs an **Atomic Red Team (ART)** test that is
installed on the host. Analysts hunt the resulting telemetry in CrowdStrike
Falcon, CTF-style. The facilitator drives the steps from this tool. For each
step the tool shows the atomic's description, the exact command that ran, the
UTC window, verify results, and the facilitator's hunt notes. Afterwards it
generates an answer key and runs ART cleanup.

**This repo contains orchestration only** (decision D19): scenarios, the
control center, preflight, the ART catalog, verification, cleanup, the
detection checklist and the answer key. Attack behavior comes from the ART
tests on the host. There are no atomics, attack scripts or technique logic in
this repo. A scenario step only references an ART test by GUID, plus its
input arguments.

> The project brief lives in [docs/PROJECT-BRIEF.md](docs/PROJECT-BRIEF.md);
> design decisions are in [docs/decisions.md](docs/decisions.md).

## Status

- **ART-backed steps** work end to end: catalog → scenario builder → run
  (prereq check, confirmed GetPrereqs, execute) → verify → cleanup (also
  after a restart) → answer key. Tested in the Linux development environment
  against a mock ART and the real Invoke-AtomicRedTeam 2.1.0 module, **not
  yet on the Windows lab host** (see [Testing on the lab host](#testing-on-the-lab-host)).
- Earlier milestones (control center shell, saved state, Falcon preflight,
  calibration, detection checklist) were tested on the lab host. Our own
  scheduled-task modules from Milestone 2 were **removed** in favor of ART.

## Requirements

- Windows 10/11 or Windows Server with **Windows PowerShell 5.1**.
- **Atomic Red Team** installed on the host, by default in
  `C:\AtomicRedTeam`:
  - `C:\AtomicRedTeam\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1` (the
    module). It doesn't need to be on `$PSModulePath`: the tool imports it by
    path.
  - `C:\AtomicRedTeam\atomics\` (the atomic tests).
- The **powershell-yaml** module, which ART requires:
  `Install-Module powershell-yaml -Scope CurrentUser`.
- A web browser. Admin rights are only needed for tests marked
  `elevation_required`; the tool blocks those unless it runs elevated.

If ART is installed elsewhere, start with `-ArtRoot D:\Path\AtomicRedTeam`
or set `TTX_ART_ROOT`.

## Run it

```powershell
cd <path-to-repo>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1
```

Your browser opens <http://localhost:8080/>. Press **Ctrl+C** in the console to
stop. Options:

| Option | Default | |
|---|---|---|
| `-ArtRoot <path>` | `$env:TTX_ART_ROOT`, else `C:\AtomicRedTeam` | ART install folder |
| `-Port 8090` | 8080 | Port |
| `-NoBrowser` | | Don't open a browser |
| `-StepTimeoutSeconds 300` | 120 | Per-test timeout (passed to `Invoke-AtomicTest -TimeoutSeconds`) |
| `-TelemetryDelayMinutes 10` | 5 | Delay used for the "ready to hunt" estimate |

Run it from an **elevated** PowerShell if the scenario uses tests with
`elevation_required: true`.

## Using it

1. **Exercise → Preflight**: check that Falcon sensor, AID, ART root, ART
   module (and version), atomics, and powershell-yaml are all green.
2. **ART catalog**: browse the installed Windows tests and search by
   technique ID or name (e.g. `T1053.005`, `scheduled task`). Each test shows
   its GUID, platforms, executor, `elevation_required`, input arguments with
   defaults, description, prereqs, command and cleanup command. The first
   start parses the atomics in the background, which takes about a minute;
   the result is cached in `runs\catalog.json` and rebuilt when the atomics
   change (or with **Rescan atomics**).
3. **Scenario builder**: add tests from the catalog, order them, set
   dependencies, input-argument overrides (preview the substituted command),
   verify checks, expected detections and hunt notes, then **Save**
   (`scenarios\<id>.json`). Destructive/high-impact techniques (T1485, T1486,
   T1489, T1490, T1529, T1561) need the technique ID typed to be added.
4. **Exercise**: load the scenario, then **Run step** or **Run all**.
   Dependency order is enforced: a step whose dependency hasn't succeeded is
   refused with a warning, not skipped. Tick **Continue past failed steps**
   in the session header (or set it as the scenario default in the builder)
   to let Run all keep going after a failure; dependencies then only need to
   have been attempted. Each step:
   - checks prerequisites (`-CheckPrereqs`); if any are missing, the step
     pauses and shows the commands `-GetPrereqs` would run. They run only
     after you confirm, plus a separate download confirmation when they appear
     to download tools;
   - runs the test with your input arguments and a per-run
     `-ExecutionLogPath` (`runs\<id>\art-execution-log.csv`);
   - records the UTC window, exit code and output, then runs the verify
     checks.
5. **Hunt**: telemetry may take a few minutes to appear in Falcon; the
   session header shows a ready-to-hunt estimate. Mark which expected
   detections fired in each step's checklist. **Answer key** opens
   `runs\<id>\answer-key.md`.
6. **Cleanup** runs `Invoke-AtomicTest ... -Cleanup` for every step that ran,
   in reverse order, from saved session state, so it also works after a
   restart. It then re-runs verify; anything still present fails that
   step's cleanup.

> **Trainee tip-off:** ART command lines and paths (`AtomicRedTeam`,
> `Invoke-AtomicTest`, the atomics folder) may be visible in Falcon
> telemetry. Hiding them is out of scope for now.

**Theme:** the Theme picker in the top bar switches between System (follows
Windows), Light and Dark; the choice is remembered in the browser.

## Built-in scenarios

These ship in `scenarios\` and are ready to load. Each step is an ART test
that needs no elevation and downloads nothing. Every step that leaves
something behind has an ART cleanup command. They were picked from
Invoke-AtomicRedTeam 2.1.0 / the atomics current in October 2026.
**Continue past failed steps** is on by default for all four.

| Scenario | Chain | Leaves behind until Cleanup |
|---|---|---|
| **Discovery: first look around the host** (`discovery-first-look`) | T1033 whoami → T1082 systeminfo → T1016 network config → T1057 tasklist → T1087.001 local accounts → T1069.001 local groups → T1049 connections → T1135 shares | Nothing (read-only) |
| **Persistence via scheduled task** (`persistence-schtask`) | T1059.001 encoded PowerShell → T1053.005 `schtasks /create` task `spawn` | Scheduled task `\spawn` (runs once at 06:00) |
| **Persistence via Run key** (`persistence-run-key`) | T1059.003 cmd writes `%TEMP%\test.bin` → T1547.001 HKCU Run value `Atomic Red Team` = `notepad.exe` | The file and the Run value (Notepad opens at logon until cleaned) |
| **Collection: stage data in a temp archive** (`collection-staging`) | T1033 whoami → T1074.001 `Compress-Archive` of ART's sample folder to `%TEMP%\Folder_to_zip.zip` | The zip |

Each step has expected detections, hunt notes and, where it creates
something, a verify check. Edit any of them in the Scenario builder.

## How it works

```
Browser (ui/)  --HTTP-->  Start-ControlCenter.ps1
                            server/Server.psm1        HttpListener on localhost, JSON API
                            server/Engine.psm1        catalog, scenarios, sessions, queue, saved state,
                                                      checklist, answer key
                               | Start-Job (one step at a time; catalog build in its own job)
                               v
                            server/ArtRunner.ps1      imports ART by path, Invoke-AtomicTest
                                                      (-CheckPrereqs / -GetPrereqs / run / -Cleanup)
                            server/Verify.ps1         read-only verify checks
                            server/CatalogBuilder.ps1 parses the installed atomics
                            server/StepRunner.ps1     stub module steps (tests only)
```

- **Session state** goes to `runs\<SessionId>\state.json` and `events.jsonl`.
  The state records everything cleanup needs: ART root and paths, GUID,
  resolved input arguments, the commands after substitution, and whether the
  step executed. These files are gitignored.
- Only **one session** is active at a time. Another scenario can't be loaded
  until the current one is cleaned up, unless none of its steps ran.
- More detail: [scenario format](docs/scenario-format.md),
  [decisions](docs/decisions.md),
  [stub module contract](docs/module-contract.md).

## Repo layout

```
Start-ControlCenter.ps1   Entry point
docs/                     Brief, decisions, scenario format, stub module contract
server/                   PowerShell backend (Engine, Server, ART runner, catalog, verify, preflight)
ui/                       Static web UI (plain HTML/CSS/JS, no build step)
scenarios/                Scenarios, one <id>.json each
modules/                  Stub modules for engine tests only (marker files)
tests/                    Syntax check, smoke test, fixtures (mock ART + fake technique)
runs/                     Session state, logs, catalog cache (gitignored)
```

## API

POSTs need the header `X-TTX-Request: 1` (the web UI sends it).

| Method / path | Purpose |
|---|---|
| `GET /api/preflight` | Host, user, elevation, Falcon sensor and AID, ART status. |
| `GET /api/catalog` | Catalog status and the test list (summary). |
| `GET /api/catalog/tests/<guid>` | One test in full. |
| `POST /api/catalog/preview` | `{ guid, input_arguments }` → command, cleanup and prereq commands after substitution. |
| `POST /api/catalog/rescan` | Rebuild the catalog. |
| `GET /api/scenarios`, `GET /api/scenarios/<id>` | List / read scenarios with validation results. |
| `POST /api/scenarios` | `{ scenario, overwrite }` → save to `scenarios/<id>.json`. |
| `POST /api/sessions` | `{ scenarioId, parameters }` → load a scenario. |
| `GET /api/session?since=<n>&rev=<r>` | Session view and new events. |
| `POST /api/session/steps/<id>/run`, `/api/session/run-all`, `/api/session/cleanup` | Run / clean up. |
| `POST /api/session/steps/<id>/getprereqs` | `{ confirm: true, confirmDownload: true }`. |
| `POST /api/session/options` | `{ continueOnFailure: true\|false }`. |
| `POST /api/session/steps/<id>/detections` | `{ detectionId, result: fired\|not-fired\|unknown, notes }`. |
| `POST /api/session/calibrate`, `/api/session/calibration` | Falcon calibration trigger and its result. |
| `GET /api/session/answer-key` | The generated answer key (Markdown). |

## Testing on the lab host

Run these from Windows PowerShell 5.1 on the lab host, with the Falcon sensor
running.

**0. Get the code.** Download the branch ZIP and extract it to a fresh folder
(e.g. `C:\TTX3`), then run `Get-ChildItem -Recurse | Unblock-File` in that
folder.

**1. Static checks.** Expect `All syntax checks passed.`

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Syntax.ps1
```

**2. Smoke test (mock ART; nothing real runs).** This test uses the mock
`Invoke-AtomicTest` in `tests\fixtures\art`, which only echoes text and
writes marker files in a temp folder. It needs `powershell-yaml`. Expect
`Smoke test passed.`

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SmokeTest.ps1
```

If you run it elevated, the elevation-block check is skipped; this is expected.

**3. Point the tool at the real ART install.** Start the control center (add
`-ArtRoot <path>` if ART isn't in `C:\AtomicRedTeam`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1
```

In **Preflight**, check that ART root, ART module (with its version), atomics
and powershell-yaml are green, and that the Falcon sensor is `Running` with
an AID. Open **ART catalog**. The first build takes about a minute. Expect
over a thousand Windows tests, and check that searching `T1053.005` lists the
scheduled-task tests.

**4. Pick a built-in scenario.** Four scenarios ship ready to load (see
[Built-in scenarios](#built-in-scenarios)). Start with "Persistence via
scheduled task". If a step says its GUID isn't in the installed atomics, your
ART version differs; pick a similar test for that step in the builder.

**5. Run it.** Optionally run **Falcon calibration** first and mark the
result. Load the scenario and click **Run all**.

| Check | Expect |
|---|---|
| Step 1 | `SUCCEEDED`, with exit code 0, a UTC window, and the command that ran. |
| Step 2 before step 1 | If you click **Run step** on step 2 first: refused with "requires ... to succeed first". |
| Prereqs | If a test has missing prereqs, the step shows `PREREQS MISSING` with the GetPrereqs commands. It runs only after you tick the confirmation(s). |
| Step 2 verify | `scheduled_task_exists ... pass`. Check by hand too: `Get-ScheduledTask -TaskName <name>`. |
| `runs\<id>\art-execution-log.csv` | One row per executed test, with `ExitCode`. |
| Answer key | Host, AID, scenario, and per step: technique, test, GUID, command, UTC window, verify results, hunt notes. |

**6. Check Falcon.** After the ready-to-hunt time shown in the session
header, search Falcon for the host's AID within each step's UTC window. You
should find the PowerShell activity and the scheduled-task creation. Mark
each expected detection as fired or not-fired in its step's checklist, and
add any unexpected ones. Confirm the answer key shows your marks. Note
whether `AtomicRedTeam` / `Invoke-AtomicTest` show up in the command lines
trainees would see.

**7. Confirm cleanup, including after a restart.** Stop the control center
(Ctrl+C) and start it again. The session is restored. Click **Cleanup**.

| Check | Expect |
|---|---|
| Steps | Each executed step shows `CLEANED`, cleanup run in reverse order (event log). |
| `Get-ScheduledTask -TaskName <name> -ErrorAction SilentlyContinue` | Nothing. |
| Session | Status `CLEANED`. The answer key shows each step's cleanup result. |
| Prereq files | Files that GetPrereqs downloaded are **not** removed by ART cleanup (usually `C:\AtomicRedTeam\ExternalPayloads`). Remove them by hand if needed. |

**Report back:** the output of steps 1 and 2, the ART version and catalog
count, any rows that didn't match, and what Falcon detected.

### Troubleshooting

- *"Could not listen on http://localhost:8080/"*: another program uses the
  port. Start with `-Port 8090`.
- *"running scripts is disabled on this system"*: use the
  `-ExecutionPolicy Bypass` command lines above.
- *Catalog unavailable / ART module not importable*: check the paths in
  Preflight. Run `Install-Module powershell-yaml -Scope CurrentUser`, or
  start with `-ArtRoot`.
- *"requires elevation"*: the test has `elevation_required: true`. Restart
  the control center from an elevated PowerShell, or pick another test.
- *A step fails with a non-zero exit code*: open **ART output** on the step.
  The EDR may have blocked it (check Falcon), then press **Cleanup**.
- *"not found in the installed atomics"*: the GUID isn't in this ART
  version. Pick the test again in the builder.

## Development notes

This repo is developed in a Linux cloud environment and checked with
PowerShell 7:
- `tests/Test-Syntax.ps1`.
- `tests/Invoke-SmokeTest.ps1` against the mock ART (82 checks).
- PSScriptAnalyzer's `PSUseCompatibleSyntax`, `PSUseCompatibleCommands` and
  `PSUseCompatibleTypes` rules targeting Windows PowerShell 5.1.
- A headless-browser walkthrough of the UI against a running server.

The catalog builder and ART runner were also exercised against the real
Invoke-AtomicRedTeam 2.1.0 module, with the real atomics for the catalog
(1,251 Windows tests parsed with no errors). Real Windows PowerShell 5.1
behavior, Falcon and real atomics' execution are verified on the lab host.
