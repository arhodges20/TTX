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

Every `module.ps1` defines these five functions (it may define private
helpers too). Target Windows PowerShell 5.1.

| Function | Returns | Purpose |
|---|---|---|
| `Get-TtxModuleInfo` | hashtable (metadata, below) | Describe the module. Must not touch the system. |
| `Invoke-TtxRun -Context` | nothing (throw on failure) | Perform the step. |
| `Test-TtxVerify -Context` | `@{ Passed = [bool]; Detail = [string] }` | Report whether the step's artifact is present. Must not change anything. |
| `Invoke-TtxCleanup -Context` | nothing (throw on failure) | Undo the step. Must be **idempotent** and succeed even if Run never ran or only partly ran. |
| `Get-TtxHunt -Context` | hunt guidance (simple or structured, below) | Defender hunt guidance (text only). Must not touch the system. |

### Metadata (`Get-TtxModuleInfo`)

```powershell
@{
    Id          = 'register-scheduled-task'        # = folder name
    Name        = 'Register scheduled task'
    Description = 'What the step does, in one or two sentences.'
    Version     = '1.1.0'
    Technique   = 'T1053.005'   # ATT&CK technique label; '' if none
    Tactic      = 'Persistence' # ATT&CK tactic label; '' or 'Setup' for preconditions
    IsStub      = $false        # $true for stub modules that only write marker files
    TimeoutSeconds = 90         # optional; overrides the engine default when larger
    Parameters  = @(
        @{ Name = 'TaskName'; Default = 'TTX-Lab-Updater'; Description = '...' }
    )
    # Optional: detections this step is LIKELY to trigger. The facilitator
    # records which actually fired (expected-vs-actual checklist + answer key).
    ExpectedDetections = @(
        @{ Id = 'scheduled-task-persistence'; Tactic = 'Persistence'; Technique = 'T1053.005'; Description = '...' }
    )
}
```

`Tactic`, `TimeoutSeconds`, and `ExpectedDetections` are optional; older
modules without them still load.

### Hunt guidance (`Get-TtxHunt`)

Return **either** the simple form (an array of `@{ Title; Where; What }`) or the
**structured** form, a hashtable with any of these keys:

```powershell
@{
    Lineage         = @('parent -> child -> ...')              # expected process tree
    FalconEvents    = @(@{ Name = 'ProcessRollup2'; Detail = '...' })
    WindowsEvidence = @(@{ Name = 'Security 4698'; Detail = '...' })
    Queries         = @(@{ Title = '...'; Query = '... aid={{Aid}} ...' })
    Pivots          = @('task -> action -> file -> who wrote it -> ...')
}
```

Any text may contain `{{Placeholder}}` tokens that the engine fills in with
this run's real values: `{{Host}}`, `{{User}}`, `{{Aid}}`, `{{ArtifactRoot}}`,
`{{SessionId}}`, `{{WindowStart}}`, `{{WindowEnd}}`, and every scenario
parameter by name (e.g. `{{TaskName}}`). The structured form feeds both the
per-step hunt view and the generated answer key.

## The `Context` hashtable

| Key | Meaning |
|---|---|
| `SessionId` | Current session id. |
| `ScenarioId` | Scenario id. |
| `StepId` | Step id within the scenario. |
| `ArtifactRoot` | This session's artifact folder: `%ProgramData%\<ArtifactFolder>` (D16). Modules write **only** under here. |
| `Parameters` | Hashtable: module defaults, overridden by scenario parameters (incl. profile), overridden by step `params`. |
| `StepData` | Hashtable this step recorded on earlier runs (via `Set-TtxStepData`); available to Run, Verify, and Cleanup, even after a restart. |
| `AllStepData` | Map of every step id to its recorded data, so a later step can use what an earlier step created. |

## Provided by the runner

The step runner (`server/StepRunner.ps1`) provides these before loading the
module:

- `Write-TtxLog -Message <string> [-Level info|warn|error]`: adds a line to
  the session's event log.
- `Register-TtxArtifact -Type file|scheduled-task|process -Location <string> [-Detail <string>]`:
  records something the step created or ran on the host. The facilitator sees
  it under "Artifacts on host", and it is stored in the session state. Call it
  from `Invoke-TtxRun` for **everything** the step creates or runs.
- `Set-TtxStepData -Key <string> -Value <any>`: records a value in this step's
  session state (e.g. the exact task name it created). It comes back as
  `Context.StepData` on later operations, including `Invoke-TtxCleanup` after a
  control-center restart, so Cleanup never has to guess what to remove.
- File helpers from `modules/_common/TtxArtifacts.ps1`. All of them refuse any
  path outside `%ProgramData%`, and names must be plain file names inside
  `Context.ArtifactRoot`:
  - `New-TtxArtifactFile -Context $Context -Name <file> -Content <string> [-Detail <string>]`
    writes the file and registers it as a `file` artifact.
  - `Test-TtxArtifactFile -Context $Context -Name <file>`
  - `Remove-TtxArtifactFile -Context $Context -Name <file>`
  - `Get-TtxArtifactPath -Context $Context -Name <file>` returns the full path.
  - Marker shortcuts used by stub modules: `New-TtxMarker`, `Test-TtxMarker`,
    `Remove-TtxMarker` (name defaults to `<StepId>.marker`).

The result of every Run also records the PID of the `powershell.exe` the step
ran in, so the facilitator can find it in the EDR process tree.

## How the engine calls a module

- **Run a step:** `Invoke-TtxRun`, then `Test-TtxVerify`. The step succeeds
  only if Run didn't throw **and** Verify returned `Passed = $true`.
- **Cleanup:** `Invoke-TtxCleanup`, then `Test-TtxVerify`. Cleanup succeeds
  only if Cleanup didn't throw **and** Verify returned `Passed = $false`
  (the artifact is gone).
- **Describe** (when a session is loaded): `Get-TtxModuleInfo` and `Get-TtxHunt`.

## Rules

- Benign by design: artifacts are real but inert. No functional malware,
  payloads, injection, credential access, or anything harmful outside a lab.
  A script a module writes may only do harmless things (e.g. append a line to
  a log file next to itself).
- Files go only under `Context.ArtifactRoot`, through the file helpers.
- Other artifact types (e.g. scheduled tasks) must be tagged with the session
  id so the module can prove ownership. Run refuses to overwrite, and Cleanup
  never removes, anything that doesn't carry this session's tag.
- Cleanup must remove everything Run created, and Verify must then report it
  gone.
- Register every artifact with `Register-TtxArtifact` (the file helpers do
  this for files).
- Use `Write-TtxLog` rather than `Write-Host`.
