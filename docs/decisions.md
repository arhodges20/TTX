# Design decisions

Notable decisions, newest last. Each entry: decision, options considered, why.

## D1. Backend is Windows PowerShell 5.1 only

- **Decision:** The backend is a PowerShell 5.1 script using
  `System.Net.HttpListener`, bound to `http://localhost:<port>/` only.
- **Options:** PowerShell-only; Python (Flask); Node.js.
- **Why:** Nothing to install on the lab host, and modules are PowerShell
  anyway, so the whole tool is one language. Binding to `localhost` keeps it
  off the network.

## D2. UI is static HTML/CSS/JS with polling

- **Decision:** Plain HTML/CSS/JS served by the backend, no build step. The UI
  polls the server about once a second for status and new events.
- **Options:** SPA framework with a build step; Server-Sent Events/WebSockets.
- **Why:** No toolchain. `HttpListener` in a single-threaded PowerShell loop
  can't easily hold long-lived connections; one-second polling is plenty for a
  facilitator UI.

## D3. Scenarios are JSON

- **Decision:** Each scenario is `scenarios/<id>/scenario.json`.
- **Options:** JSON; YAML; PowerShell data files (`.psd1`).
- **Why:** PowerShell 5.1 reads JSON natively (`ConvertFrom-Json`) and the
  browser can too. YAML needs an extra module. `.psd1` isn't readable by the UI.

## D4. Module contract: five functions in one `module.ps1`

- **Decision:** A module is `modules/<id>/module.ps1` defining
  `Get-TtxModuleInfo`, `Invoke-TtxRun`, `Test-TtxVerify`, `Invoke-TtxCleanup`,
  `Get-TtxHunt`. A step "succeeds" only if Run doesn't throw and Verify passes;
  a cleanup "succeeds" only if Cleanup doesn't throw and Verify then fails
  (the artifact is gone).
- **Options:** PowerShell module manifests (`.psd1` + `.psm1`); separate script
  per operation; metadata in JSON next to the script.
- **Why:** One file per module is the easiest thing to read and review.
  Checking Verify after Cleanup proves the Cleanup works instead of trusting it.

## D5. Shared marker helpers, guarded to `%ProgramData%`

- **Decision:** Modules write markers through shared helpers that refuse any
  path outside `%ProgramData%`.
- **Options:** Each module handles its own paths.
- **Why:** One guard in one place, so a module bug or a bad parameter can't
  write or delete outside the lab folder.

## D6. Steps run in background jobs, one at a time

- **Decision:** Each Run/Cleanup runs via `Start-Job` → `server/StepRunner.ps1`
  in a separate `powershell.exe`. The server loop checks jobs between
  requests, so the UI stays responsive. Only one operation runs at a time;
  "Run all" and "Cleanup" are queues. Each job has a timeout (default 120 s).
  Module metadata and hunt guidance ("describe") are read in a short-lived
  in-process runspace when a session is loaded, because they don't touch the
  system and a job costs about a second to start.
- **Options:** Runspace pool in-process; `Start-Process` per step; run inline.
- **Why:** Jobs are built into 5.1, isolate crashes and hangs from the server,
  and can be stopped. One-at-a-time matches how a facilitator runs a TTX.

## D7. One active session; state saved after every change

- **Decision:** There is one current session. The engine writes
  `runs/<id>/state.json` (atomically) after every change and appends to
  `events.jsonl`. On start it restores the newest session whose status is
  still `active`. A new scenario can't be loaded while the current session has
  steps that ran, until Cleanup succeeds. Cleanup runs for **every** step
  (Cleanup is idempotent), in reverse order, and the session closes only when
  every step's Verify confirms its artifact is gone. Empty artifact folders are
  then removed; folders with unexpected content are left and reported.
- **Options:** Multiple concurrent sessions; cleanup only steps that ran;
  recursive delete of the artifact folder.
- **Why:** Keeps it simple and makes it hard to leave artifacts behind. A
  recursive delete would be simpler but could remove things the tool didn't
  create.

## D8. Artifact location

- **Decision:** Artifacts go to `%ProgramData%\<ArtifactFolder>\<SessionId>\`.
  `ArtifactFolder` is a scenario parameter (default `TTX-Lab`), validated as a
  relative path with no `..`. Session state and logs stay under `runs/`.
- **Why:** Requested by the project owner. Per-session subfolders keep
  sessions apart and make cleanup exact.

## D9. Checks without a Windows host

- **Decision:** Development checks run under PowerShell 7 on Linux:
  `tests/Test-Syntax.ps1`, `tests/Invoke-SmokeTest.ps1` (with `ProgramData`
  pointed at a temp folder), and PSScriptAnalyzer's `PSUseCompatibleSyntax`,
  `PSUseCompatibleCommands`, and `PSUseCompatibleTypes` rules targeting
  Windows PowerShell 5.1. Final verification is on the Windows lab host.
- **Why:** Catches 7-only syntax and most logic bugs before a lab round trip.

## D10. Localhost hardening for the API

- **Decision:** Bind only `http://localhost:<port>/`, reject any non-localhost
  `Host` header, and require an `X-TTX-Request: 1` header on every POST.
- **Options:** No checks (localhost-only binding); a session token.
- **Why:** A web page open in the same browser can't send that custom header
  cross-origin without a CORS preflight, which this server never approves, so
  another site can't trigger runs or cleanup. The Host check blocks DNS
  rebinding. Both are a few lines; a token adds setup for little extra benefit
  in a lab.

## D11. Real, benign artifacts instead of stubs

- **Decision:** Modules create **real** host artifacts that the EDR records
  (files, scheduled tasks, processes), each of which is inert: e.g. a
  scheduled task whose action runs a script that only appends a line to a log
  file. Each step reports the artifacts it created (type, location, detail)
  and the PID it ran in, and the UI shows them to the facilitator. Stub
  modules remain for engine tests.
- **Options:** Keep stubs (marker files only); simulate telemetry by writing
  fake log entries.
- **Why:** The product's purpose is to give analysts genuine telemetry to hunt
  in CrowdStrike Falcon. Marker files don't produce the events analysts would
  look for (task registration, task-launched processes). Fake log entries
  wouldn't appear in the EDR at all.

## D12. Scheduled-task scenario: loader/implant chain in four steps

- **Decision:** The scenario models a post-initial-access chain with two inert
  stand-in scripts: a *loader* (only appends a UTC timestamp to a marker file)
  and an *implant* (only checks in and creates the scheduled task). Four
  modules: stage foothold files, implant execution, implant creates
  persistence, persistence fires. Steps 2 and 3 stay **separate**: each step
  launches a fresh implant process (`svcmgr.ps1 checkin` / `svcmgr.ps1
  persist`). In step 3 the implant script itself starts `schtasks.exe` (or
  calls `Register-ScheduledTask` in cmdlet mode), so schtasks is necessarily
  its child. The implant records its own PID, its parent PID, the schtasks
  PID, and exit code; step 3's Verify requires the recorded schtasks parent
  PID to equal the implant PID. Task settings are written into the implant
  file at staging time, so its command line stays a plain `-File`.
- **Options:** Merge steps 2 and 3 into one implant run; a long-lived implant
  that waits for a "go" signal between steps.
- **Why:** Keeps each step independently runnable (as requested) while
  guaranteeing the `powershell.exe (implant) -> schtasks.exe` lineage, and
  proves it with recorded PIDs instead of assuming it. A waiting implant would
  be orphaned by a control-center restart and need extra cleanup. The TTX job
  process remains the implant's parent; the answer key leaves "how did the
  implant get here?" as the open question for the next exercise.

## D13. Detections are likely, not guaranteed

- **Decision:** Each module lists the detections it is *likely* to trigger
  (tactic/technique level, "confirm in your tenant"). The facilitator marks
  which actually fired in a per-step checklist; results are saved to session
  state and the run's answer key so scenarios can be tuned over time.
- **Why:** CrowdStrike Falcon's detection logic (IOAs, ML) is proprietary and
  changes over time, and depends on the tenant's prevention policy. The tool
  can stack well-known suspicious indicators but cannot promise a detection.
  Expected-vs-actual records turn that uncertainty into data.

## D14. DetectionProfile drives the individual options

- **Decision:** `DetectionProfile` (`loud` default, `subtle`) supplies
  defaults for `CreateMethod`, `EncodeCommand`, and `HiddenWindow`. An option
  the admin sets explicitly when loading the scenario always wins; options
  left unset take the profile's value. The GUI pre-fills the fields when the
  profile changes, and keeps later edits.
  - `loud`: hidden, encoded PowerShell (`-nop -w hidden -ep bypass -enc`),
    `schtasks.exe /create` from the implant, `schtasks /run`.
  - `subtle`: `Register-ScheduledTask` (no schtasks.exe), plain `-File`, no
    hidden window, `Start-ScheduledTask`.
- **Why:** One switch for the common case, without taking control away from
  the admin.

## D15. Task ownership proven from session state

- **Decision:** `schtasks /create` cannot set a task description, so the task
  isn't tagged that way. Instead: Run refuses to create a task whose name
  already exists; Cleanup deletes the task only if session state records that
  this run created it **and** its action still references this run's loader.
  The run ID is also embedded (as a comment) in the encoded command and in
  both stand-in files, so a SOC can confirm the task is benign.
- **Why:** Keeps the realistic `schtasks.exe /create /tr ...` command line
  while guaranteeing Cleanup never deletes a task it didn't create.

## D16. Artifact folder without a per-session subfolder (supersedes D8)

- **Decision:** Files go directly in `%ProgramData%\<ArtifactFolder>` (default
  `TTX-Lab`; `%ProgramData%\TTX-Lab` is accepted too). Every file carries the
  run ID; Run refuses to overwrite a same-named file that lacks this run's ID.
- **Options:** Keep `<ArtifactFolder>\<SessionId>\` (D8).
- **Why:** Matches the requested layout, keeps paths realistic, and keeps the
  task action under schtasks' 261-character `/tr` limit. Safe because only one
  session can be active and the previous one must be cleaned up first.

## D17. Falcon preflight and calibration

- **Decision:** When a session is created, the engine records host, user, UTC
  time, `CSFalconService` status, and the sensor's AID (read from
  `HKLM\SYSTEM\CurrentControlSet\Services\CSAgent\Sim`, value `AG`). If the
  sensor isn't running the GUI warns; nothing is blocked. An optional
  calibration action runs CrowdStrike's benign test-detection trigger,
  `choice /m crowdstrike_sample_detection`, with `/t 5 /d Y` added so it can
  never wait for input.
- **Caveat:** The trigger command and AID location could not be verified
  against current CrowdStrike documentation from the development environment
  (it requires a support-portal login); confirm both in your tenant's docs.
  The `/t 5 /d Y` flags are our addition.
- **Why:** Proves the sensor and console generate detections before the
  exercise, using behavior only: no test files, hashes, or sensor tampering.
