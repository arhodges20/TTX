# Stub module contract (tests only)

Attack steps are ART tests (D19). Modules exist only as **stubs** in
`modules/stub-*` that write and remove marker files, so the engine can be
tested without ART. Don't add technique modules.

## Layout

`modules/<id>/module.ps1`, folder name = module `Id`. `modules/_common` holds
shared helpers. The engine runs modules via `server/StepRunner.ps1` in a
background job.

## Functions

| Function | Returns | Purpose |
|---|---|---|
| `Get-TtxModuleInfo` | `@{ Id; Name; Description; Version; Technique; IsStub; Parameters; ExpectedDetections? }` | Describe the module; no side effects. |
| `Invoke-TtxRun -Context` | nothing (throw on failure) | Do the step. |
| `Test-TtxVerify -Context` | `@{ Passed; Detail }` | Is the artifact present? Read-only. |
| `Invoke-TtxCleanup -Context` | nothing | Undo the step; idempotent. |
| `Get-TtxHunt -Context` | `@(@{ Title; Where; What })` | Hunt guidance text. |

A run succeeds if Run doesn't throw and Verify passes; a cleanup succeeds if
Cleanup doesn't throw and Verify then fails (artifact gone).

## Context and helpers

`Context` has `SessionId`, `ScenarioId`, `StepId`, `ArtifactRoot`
(`%ProgramData%\<ArtifactFolder>`), `Parameters`, `StepData`, `AllStepData`.

The runner provides `Write-TtxLog`, `Register-TtxArtifact`, `Set-TtxStepData`
(comes back as `Context.StepData`, even after a restart) and the marker
helpers `New-TtxMarker`, `Test-TtxMarker`, `Remove-TtxMarker` from
`modules/_common/TtxArtifacts.ps1`, which refuse paths outside
`%ProgramData%`.
