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
