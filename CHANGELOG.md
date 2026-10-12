# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

### Added
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
