# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

### Continue past failed steps, dark mode, elevated smoke test

#### Added
- **Continue past failed steps** (D20): a session option (checkbox in the
  session header, `POST /api/session/options`) with a scenario default
  (`continue_on_failure`, also in the builder). When on, Run all keeps going
  after a failed step or missing prereqs, and dependencies only need to have
  been attempted. Recorded in the answer key.
- **Theme picker** (System / Light / Dark) in the top bar, remembered in the
  browser.

#### Fixed
- Smoke test failed in an elevated console: it started the elevated fixture
  step expecting a refusal. It now runs it (and waits) when elevated, and the
  mock `Invoke-AtomicTest` detects real elevation.

### Direction change: Atomic Red Team is the execution engine (D19)

#### Added
- ART integration (`server/Art.ps1`): configurable ART root (default
  `C:\AtomicRedTeam`; `-ArtRoot` on `Start-ControlCenter.ps1` or
  `TTX_ART_ROOT`), module imported by path from
  `<root>\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1`, atomics from
  `<root>\atomics`.
- Preflight: ART root, module importable and its version, atomics folder,
  `powershell-yaml`, alongside the existing Falcon sensor, AID and
  calibration checks. Missing pieces are clear warnings.
- ART catalog (`server/CatalogBuilder.ps1`): built in a background job from
  the installed atomics with the module's `Get-AtomicTechnique`, falling back
  to `powershell-yaml`; Windows tests only; cached in `runs/catalog.json` and
  rebuilt when the atomics change. Shows technique, test, GUID, platforms,
  executor, `elevation_required`, input arguments with defaults, description,
  prereqs, and flags for prereq downloads, command downloads and high-impact
  techniques. Search by technique id/name or test name.
- ART step runner (`server/ArtRunner.ps1`): CheckPrereqs; if missing, the
  step pauses and GetPrereqs needs explicit confirmation (plus a download
  acknowledgement when flagged); execution with input-argument overrides and
  a per-run `-ExecutionLogPath` (`runs/<id>/art-execution-log.csv`); UTC
  window, exit code (from ART's execution log) and output saved.
- Read-only verify checks (`server/Verify.ps1`): `file_exists`,
  `scheduled_task_exists`, `registry_value_exists`, `service_exists`,
  `process_ran_since_step_start`.
- Cleanup via `Invoke-AtomicTest -Cleanup` for every executed step, in
  reverse order, from saved session state (works after a restart); verify is
  re-run and anything still present fails that step's cleanup. Per-step
  cleanup result shown and saved.
- Guardrails: elevated tests blocked unless the control center is elevated;
  destructive/high-impact techniques (T1485, T1486, T1489, T1490, T1529,
  T1561) need the technique id typed to be added; UI note that ART command
  lines and paths may be visible to trainees in telemetry.
- Scenario builder and ART catalog tabs in the UI; facilitator view shows the
  atomic's description, the exact command that ran, input arguments, UTC
  window, exit code, verify and cleanup results, hunt notes and the
  detection checklist; calibration and a ready-to-hunt estimate.
- API: `GET /api/catalog`, `GET /api/catalog/status`,
  `GET /api/catalog/tests/<guid>`, `POST /api/catalog/preview`,
  `POST /api/catalog/rescan`, `GET /api/scenarios/<id>`,
  `POST /api/scenarios`, `POST /api/session/steps/<id>/getprereqs`.
- Example scenario `scenarios/persistence-schtask.json` (T1059.001 ->
  T1053.005) with `atomic_guid` left empty to choose on the lab host.
- Test fixtures: mock `Invoke-AtomicTest`/`Get-AtomicTechnique` and a fake
  technique (T9999.001) that only echoes or writes marker files
  (`tests/fixtures/art`); smoke test rewritten around them (catalog, run,
  prereq gate, verify, guardrails, dependency order, cleanup after restart,
  answer key, stub steps).

#### Changed
- Scenario format v2: flat `scenarios/<id>.json`; steps reference an ART test
  by `atomic_guid` with `input_arguments`, `depends_on`, `verify`,
  `expected_detections`, `hunt_notes`. Validation distinguishes errors,
  incomplete drafts and warnings.
- Answer key (`runs/<id>/answer-key.md`) rebuilt from run data: host, AID,
  scenario, ART version, per-step technique, test name, GUID, the command
  that ran, UTC window, exit code, verify results, hunt notes and detection
  checklist results, with the telemetry delay note and ready-to-hunt time.
- Detection checklist rows come from the step's `expected_detections`.
- `GET /api/session` accepts `rev` and only resends the session when it
  changed.
- Decisions D12, D14 and D15 revised; D19 added; brief updated.

#### Removed
- Our own technique modules `stage-script`, `register-scheduled-task`,
  `run-scheduled-task` and the `persistence-scheduled-task` scenario folder.
  Stub modules remain, for tests only.
- The loader/implant chain plans (D12) and its options (D14).

### Earlier in this release

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
- Expected-vs-actual detection checklist: modules declare `ExpectedDetections`;
  `POST /api/session/steps/{id}/detections` records fired / not-fired / unknown
  per detection, saved to session state.
- Answer key: `runs/<id>/answer-key.md`, generated from this run's real values
  (host, AID, task name, paths, UTC window) and refreshed after every step and
  checklist change; served at `GET /api/session/answer-key`.
- Hunt guidance upgraded to structured form (lineage, Falcon events, Windows
  evidence, starter queries, pivots) with `{{Placeholder}}` tokens filled in
  per run, on the three scheduled-task modules.

### Changed
- Scheduled-task modules declare `Tactic` and `ExpectedDetections` and return
  structured hunt guidance; scenario steps declare `dependsOn` so ordering is
  enforced.
- Docs reconciled with what was built: brief gains a "What this product is"
  section and a scope boundary; decisions D12/D14/D15 marked proposed-not-built
  and D18 records the scope decision; module contract and scenario format cover
  the new metadata, hunt form, step data, typed options, profiles, and
  `dependsOn`.
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
