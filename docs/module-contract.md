# Module contract

A module is a step type written in PowerShell, used alongside ART tests:

- **Built-in stubs** in `modules/stub-*` write and remove marker files so the
  engine can be tested without ART. Don't add technique modules to the repo
  (D19).
- **Custom modules** are imported on the Modules tab and saved in
  `custom-modules/<id>/module.ps1` (gitignored, D24). Start from
  [custom-module-template.ps1](custom-module-template.ps1). They run as the
  control-center user with no sandbox.

## Layout

`<modules dir>/<id>/module.ps1`. `modules/_common` holds shared helpers. The
engine runs each operation via `server/StepRunner.ps1` in a separate
PowerShell process with no input (D23).

## Functions

| Function | Returns | Purpose |
|---|---|---|
| `Get-TtxModuleInfo` | `@{ Id; Name; Description; Version; Technique; Tactic; IsStub; RequiresElevation?; TimeoutSeconds?; Parameters; ExpectedDetections? }` | Describe the module; no side effects. `RequiresElevation = $true` blocks the step unless the control center is elevated. |
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
(comes back as `Context.StepData`, even after a restart) and, from
`modules/_common/TtxArtifacts.ps1`, file helpers that refuse paths outside
`%ProgramData%`: `New-TtxArtifactFile`, `Test-TtxArtifactFile`,
`Remove-TtxArtifactFile`, `Get-TtxArtifactPath`, and the marker shortcuts
`New-TtxMarker`, `Test-TtxMarker`, `Remove-TtxMarker`.

Import checks (without running the code): it parses, defines the five
functions at top level, and is at most 256 KB. It is then described in a
runner process; if that fails, it isn't kept.
