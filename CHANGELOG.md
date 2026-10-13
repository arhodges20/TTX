# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

### Added
- Engine: typed scenario options (`string`, `choice`, `bool`) with
  `profileParameter`/`profiles` (explicit value > profile value > default);
  step `dependsOn`, enforced with a 409 and a warning event; per-step recorded
  data (`Set-TtxStepData`, passed back as `Context.StepData`/`AllStepData`,
  including to Cleanup after a restart); per-module `TimeoutSeconds`;
  modules can declare `Tactic` and `ExpectedDetections`, and `Get-TtxHunt`
  may return a structured hunt (lineage, Falcon events, Windows evidence,
  queries, pivots).

- Falcon preflight (`server/Preflight.ps1`): at session load records host,
  user, elevation, UTC time, `CSFalconService` status, and the sensor AID;
  warns (never blocks) if the sensor isn't running. `GET /api/preflight`.
- Calibration check: `POST /api/session/calibrate` starts
  `choice /m crowdstrike_sample_detection /t 5 /d Y`;
  `POST /api/session/calibration` records whether it fired (D17).

### Changed
- Artifacts go directly in `%ProgramData%\<ArtifactFolder>` (no per-session
  subfolder; `%ProgramData%\TTX-Lab` accepted) (D16).

### Fixed
- `tests/Test-Syntax.ps1` parsed every file (CSS, HTML, Markdown) as
  PowerShell on Windows PowerShell 5.1, where `Get-ChildItem -LiteralPath`
  ignores `-Include`. It now filters by extension.

### Added
- README: Milestone 2 status, artifact details, and lab-host test steps.
- UI: per-step "Artifacts on host" (type, location, detail; struck through
  once cleaned) and the PID the step ran in; session parameters in the header.
- Real, benign modules for the scheduled-task scenario: `stage-script`
  (writes a script that only appends a line to a log beside it),
  `register-scheduled-task` (registers a real logon-triggered task, tagged
  with the session id), `run-scheduled-task` (starts the task and waits for
  the script's log). Cleanup unregisters the task and removes the files, and
  never touches a same-named task this session didn't create.
- `ScriptName` and `TaskName` scenario parameters, editable at load time.
- `tests/fixtures/scenarios/smoke-stub`: stub scenario for engine tests.
- Artifact reporting: modules call `Register-TtxArtifact` (type, location,
  detail) for everything they create or run; each step stores its artifacts
  and the PID it ran in, and the event log lists them. Generic file helpers
  (`New-/Test-/Remove-TtxArtifactFile`, `Get-TtxArtifactPath`) in
  `modules/_common/TtxArtifacts.ps1` (renamed from `TtxMarker.ps1`).
- Placeholder project brief (`docs/PROJECT-BRIEF.md`) with interim constraints.
- Repo scaffold: `server/`, `ui/`, `modules/`, `scenarios/`, `tests/`,
  gitignored `runs/`; README, CHANGELOG, and decisions log.
- Module contract (`docs/module-contract.md`): `Get-TtxModuleInfo`,
  `Invoke-TtxRun`, `Test-TtxVerify`, `Invoke-TtxCleanup`, `Get-TtxHunt`.
- Shared marker helpers (`modules/_common/TtxMarker.ps1`) that refuse paths
  outside `%ProgramData%`.
- Stub modules for the scheduled-task persistence scenario:
  `stub-stage-script`, `stub-register-scheduled-task`, `stub-task-execution`.
  They only log and write/remove marker files.
- Scenario format (`docs/scenario-format.md`) and the "Persistence via
  scheduled task" scenario (`scenarios/persistence-scheduled-task/`), with an
  `ArtifactFolder` parameter (default `TTX-Lab`).
- Engine (`server/Engine.psm1`): lists and validates scenarios, creates
  sessions, runs steps in background jobs (one at a time, with a timeout),
  runs all steps in order and stops on the first failure, and cleans up in
  reverse order with Verify checked after each Cleanup.
- Step runner (`server/StepRunner.ps1`): runs one module operation in
  isolation and returns a JSON result.
- Session state saved to `runs/<sessionId>/state.json` and
  `runs/<sessionId>/events.jsonl`; the latest uncleaned session is restored
  on restart, and steps that were in progress are marked `interrupted`.
- Tests: `tests/Test-Syntax.ps1` (parse, JSON, module contract) and
  `tests/Invoke-SmokeTest.ps1` (end-to-end engine run, restart, cleanup).
- HTTP server (`server/Server.psm1`) and entry point
  (`Start-ControlCenter.ps1`): `HttpListener` on `http://localhost:8080/`,
  JSON API for scenarios, sessions, run step, run all, and cleanup. POSTs
  require an `X-TTX-Request` header and the Host must be localhost.
- Web UI (`ui/`): scenario list with parameters, ordered steps with live
  status, Run step / Run all / Cleanup, facilitator notes, hunt guidance, and
  a live event log. Polls the server once a second.
- README: how to run, how it works, current status, and a step-by-step
  "How to test on the lab host" procedure for Milestone 1.

### Changed
- "Persistence via scheduled task" now uses the real modules instead of stubs.
- `Invoke-SmokeTest.ps1` defaults to the `smoke-stub` fixture, checks every
  reported artifact exists after Run and is gone after Cleanup, and takes
  `-ScenarioId persistence-scheduled-task` to test the real modules on Windows.
- Engine: replaced multi-line method chaining with plain statements, for
  Windows PowerShell 5.1 parser safety.
