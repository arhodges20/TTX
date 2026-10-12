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
