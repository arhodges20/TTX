# Module contract

A **module** implements one kind of exercise step. A scenario step names the
module it uses; the engine runs the module in a background job (a separate
`powershell.exe` process).

## Location

```
modules/<module-id>/module.ps1
```

The folder name must equal the module's `Id`. Folders starting with `_`
(e.g. `modules/_common`) are shared helpers, not modules.

## Required functions

Every `module.ps1` defines exactly these five functions. Target Windows
PowerShell 5.1.

| Function | Returns | Purpose |
|---|---|---|
| `Get-TtxModuleInfo` | hashtable (metadata, below) | Describe the module. Must not touch the system. |
| `Invoke-TtxRun -Context` | nothing (throw on failure) | Perform the step. |
| `Test-TtxVerify -Context` | `@{ Passed = [bool]; Detail = [string] }` | Report whether the step's artifact is present. Must not change anything. |
| `Invoke-TtxCleanup -Context` | nothing (throw on failure) | Undo the step. Must be **idempotent** and succeed even if Run never ran or only partly ran. |
| `Get-TtxHunt -Context` | array of `@{ Title; Where; What }` | Defender hunt guidance (text only). Must not touch the system. |

### Metadata (`Get-TtxModuleInfo`)

```powershell
@{
    Id          = 'stub-register-scheduled-task'   # = folder name
    Name        = 'Register scheduled task (STUB)'
    Description = 'What the step does, in one or two sentences.'
    Version     = '0.1.0'
    Technique   = 'T1053.005'   # ATT&CK reference label; '' if none
    IsStub      = $true         # $true while the module only writes markers
    Parameters  = @(
        @{ Name = 'TaskName'; Default = 'TTX-Lab-Updater'; Description = '...' }
    )
}
```

## The `Context` hashtable

| Key | Meaning |
|---|---|
| `SessionId` | Current session id. |
| `ScenarioId` | Scenario id. |
| `StepId` | Step id within the scenario. |
| `ArtifactRoot` | Folder for this session's artifacts: `%ProgramData%\<ArtifactFolder>\<SessionId>`. Modules write **only** under here. |
| `Parameters` | Hashtable: module defaults, overridden by scenario parameters, overridden by step `params`. |

## Provided by the runner

The step runner (`server/StepRunner.ps1`) dot-sources these before the module:

- `Write-TtxLog -Message <string> [-Level info|warn|error]`: adds a line to
  the session's event log.
- Marker helpers from `modules/_common/TtxMarker.ps1`:
  - `New-TtxMarker -Context $Context -Description <string> [-Name <file>]`
  - `Test-TtxMarker -Context $Context [-Name <file>]`
  - `Remove-TtxMarker -Context $Context [-Name <file>]`

  `-Name` defaults to `<StepId>.marker`. The helpers refuse any path outside
  `%ProgramData%`.

## How the engine calls a module

- **Run a step:** `Invoke-TtxRun`, then `Test-TtxVerify`. The step succeeds
  only if Run didn't throw **and** Verify returned `Passed = $true`.
- **Cleanup:** `Invoke-TtxCleanup`, then `Test-TtxVerify`. Cleanup succeeds
  only if Cleanup didn't throw **and** Verify returned `Passed = $false`
  (the artifact is gone).
- **Describe** (when a session is loaded): `Get-TtxModuleInfo` and `Get-TtxHunt`.

## Rules

- Benign by design: only inert stand-in artifacts. No functional malware,
  payloads, injection, credential access, or anything harmful outside a lab.
- Write only under `Context.ArtifactRoot` (until a later milestone defines
  other allowed, fully cleaned-up artifact types).
- Cleanup must remove everything Run created.
- Use `Write-TtxLog` rather than `Write-Host`.
