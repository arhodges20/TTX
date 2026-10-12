# TTX Control Center engine: scenarios, sessions, step execution, saved state.
# Windows PowerShell 5.1.
#
# All engine state is touched only from the server's single thread. Steps run
# in background jobs; Update-TtxEngine (called from the server loop) collects
# finished jobs and starts the next queued operation. The engine is the only
# writer of runs/<sessionId>/state.json and events.jsonl.

. (Join-Path $PSScriptRoot 'TtxCommon.ps1')

$script:Ttx = @{
    Root           = $null
    RunsDir        = $null
    ScenariosDir   = $null
    ModulesDir     = $null
    RunnerPath     = $null
    StepTimeoutSec = 120
    Session        = $null                                  # hashtable saved to state.json
    Events         = New-Object System.Collections.ArrayList  # current session's events
    Queue          = New-Object System.Collections.ArrayList  # @{ stepId; op } waiting to run
    Job            = $null                                  # running background job
    JobItem        = $null                                  # @{ stepId; op } for that job
    JobStarted     = $null
}

$script:IdPattern = '^[A-Za-z0-9][A-Za-z0-9_-]*$'
$script:FolderPattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]*([\\/][A-Za-z0-9][A-Za-z0-9 ._-]*)*$'

#region Errors (mapped to HTTP status codes by the server)

function New-TtxBadRequest { param([string]$Message) New-Object System.ArgumentException $Message }
function New-TtxConflict { param([string]$Message) New-Object System.InvalidOperationException $Message }
function New-TtxNotFound { param([string]$Message) New-Object System.Collections.Generic.KeyNotFoundException $Message }

#endregion

#region Events and saved state

function Add-TtxEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info',
        [string]$StepId,
        [string]$Timestamp
    )
    if ([string]::IsNullOrEmpty($Timestamp)) { $Timestamp = (Get-Date).ToString('o') }
    $evt = @{
        seq     = $script:Ttx.Events.Count
        ts      = $Timestamp
        level   = $Level
        stepId  = $StepId
        message = $Message
    }
    [void]$script:Ttx.Events.Add($evt)
    if ($script:Ttx.Session) {
        $path = Join-Path (Get-TtxSessionDir) 'events.jsonl'
        $line = (ConvertTo-TtxJson -InputObject $evt -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding $false))
    }
    $prefix = if ($StepId) { "[$StepId] " } else { '' }
    Write-Verbose "$Level $prefix$Message"
}

function Get-TtxSessionDir {
    return (Join-Path $script:Ttx.RunsDir $script:Ttx.Session.sessionId)
}

function Save-TtxSession {
    $s = $script:Ttx.Session
    if (-not $s) { return }
    $s.updatedAt = (Get-Date).ToString('o')
    Write-TtxTextFile -Path (Join-Path (Get-TtxSessionDir) 'state.json') -Text (ConvertTo-TtxJson -InputObject $s)
}

function Get-TtxStep {
    param([Parameter(Mandatory = $true)][string]$StepId)
    foreach ($step in $script:Ttx.Session.steps) {
        if ($step.id -eq $StepId) { return $step }
    }
    return $null
}

function Test-TtxBusy {
    return ($null -ne $script:Ttx.Job -or $script:Ttx.Queue.Count -gt 0)
}

function Test-TtxSessionTouched {
    foreach ($step in $script:Ttx.Session.steps) {
        if ($step.touched) { return $true }
    }
    return $false
}

#endregion

#region Scenarios

function Get-TtxModulePath {
    param([string]$ModuleId)
    return (Join-Path (Join-Path $script:Ttx.ModulesDir $ModuleId) 'module.ps1')
}

# Returns the scenario's parameter list, always including ArtifactFolder.
function Get-TtxScenarioParameters {
    param([hashtable]$Scenario)
    $list = @()
    $hasFolder = $false
    foreach ($p in @($Scenario.parameters)) {
        if ($null -eq $p) { continue }
        if ($p.name -eq 'ArtifactFolder') { $hasFolder = $true }
        $list += , @{ name = [string]$p.name; default = $p.default; description = [string]$p.description }
    }
    if (-not $hasFolder) {
        $list += , @{ name = 'ArtifactFolder'; default = 'TTX-Lab'; description = 'Folder under %ProgramData% where stand-in artifacts are written.' }
    }
    return , $list
}

function Test-TtxScenario {
    param([hashtable]$Scenario, [string]$FolderName)
    $errors = @()
    if ($Scenario.schemaVersion -ne 1) { $errors += 'schemaVersion must be 1.' }
    if ([string]$Scenario.id -notmatch $script:IdPattern) { $errors += 'id is missing or invalid.' }
    elseif ($Scenario.id -ne $FolderName) { $errors += "id '$($Scenario.id)' must match folder name '$FolderName'." }
    if ([string]::IsNullOrWhiteSpace([string]$Scenario.name)) { $errors += 'name is required.' }
    $steps = @($Scenario.steps | Where-Object { $null -ne $_ })
    if ($steps.Count -eq 0) { $errors += 'steps must contain at least one step.' }
    $seen = @{}
    foreach ($step in $steps) {
        $sid = [string]$step.id
        if ($sid -notmatch $script:IdPattern) { $errors += "Step id '$sid' is invalid."; continue }
        if ($seen.ContainsKey($sid)) { $errors += "Duplicate step id '$sid'." }
        $seen[$sid] = $true
        if ([string]::IsNullOrWhiteSpace([string]$step.title)) { $errors += "Step '$sid' needs a title." }
        $mod = [string]$step.module
        if ($mod -notmatch $script:IdPattern) { $errors += "Step '$sid' has an invalid module id." }
        elseif (-not (Test-Path -LiteralPath (Get-TtxModulePath $mod) -PathType Leaf)) {
            $errors += "Step '$sid' uses module '$mod', which does not exist."
        }
    }
    return , $errors
}

function Read-TtxScenario {
    param([Parameter(Mandatory = $true)][string]$FolderName)
    $path = Join-Path (Join-Path $script:Ttx.ScenariosDir $FolderName) 'scenario.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $scenario = $null
    $errors = @()
    try {
        $scenario = ConvertFrom-TtxJson -Json (Read-TtxTextFile -Path $path)
        if ($scenario -isnot [hashtable]) { throw 'scenario.json must contain a JSON object.' }
        $errors = Test-TtxScenario -Scenario $scenario -FolderName $FolderName
    }
    catch {
        $errors = @("Could not read scenario.json: $($_.Exception.Message)")
    }
    return @{ folder = $FolderName; scenario = $scenario; errors = $errors }
}

function Get-TtxScenarioList {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:Ttx.ScenariosDir)) { return , $list }
    foreach ($dir in @(Get-ChildItem -LiteralPath $script:Ttx.ScenariosDir -Directory | Sort-Object Name)) {
        $entry = Read-TtxScenario -FolderName $dir.Name
        if ($null -eq $entry) { continue }
        $s = $entry.scenario
        $item = @{
            id         = $dir.Name
            name       = $dir.Name
            summary    = ''
            objectives = @()
            parameters = @()
            stepCount  = 0
            valid      = ($entry.errors.Count -eq 0)
            errors     = $entry.errors
        }
        if ($item.valid) {
            # Assigned one by one: an @() inside an if-expression would unroll.
            $item.name = [string]$s.name
            $item.summary = [string]$s.summary
            $item.objectives = @($s.objectives | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $item.parameters = Get-TtxScenarioParameters -Scenario $s
            $item.stepCount = @($s.steps).Count
        }
        $list += , $item
    }
    return , $list
}

#endregion

#region Running modules

function Get-TtxStepContext {
    param([hashtable]$Step)
    $s = $script:Ttx.Session
    $params = @{}
    foreach ($key in @($s.parameters.Keys)) { $params[$key] = $s.parameters[$key] }
    if ($Step.params) {
        foreach ($key in @($Step.params.Keys)) { $params[$key] = $Step.params[$key] }
    }
    return @{
        SessionId    = $s.sessionId
        ScenarioId   = $s.scenarioId
        StepId       = $Step.id
        ArtifactRoot = $s.artifactRoot
        Parameters   = $params
    }
}

# Runs the step runner's 'describe' operation synchronously in a fresh runspace.
function Invoke-TtxDescribe {
    param([hashtable]$Step)
    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        $contextJson = ConvertTo-TtxJson -InputObject (Get-TtxStepContext -Step $Step) -Compress
        [void]$ps.AddCommand($script:Ttx.RunnerPath)
        [void]$ps.AddParameter('ModulePath', (Get-TtxModulePath $Step.module))
        [void]$ps.AddParameter('Operation', 'describe')
        [void]$ps.AddParameter('ContextJson', $contextJson)
        $out = @($ps.Invoke())
        $json = $out | Where-Object { $_ -is [string] } | Select-Object -Last 1
        if (-not $json) {
            $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
            if (-not $msg) { $msg = 'Step runner produced no result.' }
            return @{ ok = $false; error = $msg }
        }
        return ConvertFrom-TtxJson -Json $json
    }
    finally {
        $ps.Dispose()
    }
}

function Start-TtxNextJob {
    if ($script:Ttx.Job -or $script:Ttx.Queue.Count -eq 0) { return }
    $item = $script:Ttx.Queue[0]
    $script:Ttx.Queue.RemoveAt(0)
    $step = Get-TtxStep -StepId $item.stepId

    $contextJson = ConvertTo-TtxJson -InputObject (Get-TtxStepContext -Step $step) -Compress
    $script:Ttx.Job = Start-Job -ArgumentList $script:Ttx.RunnerPath, (Get-TtxModulePath $step.module), $item.op, $contextJson -ScriptBlock {
        param($RunnerPath, $ModulePath, $Operation, $ContextJson)
        & $RunnerPath -ModulePath $ModulePath -Operation $Operation -ContextJson $ContextJson
    }
    $script:Ttx.JobItem = $item
    $script:Ttx.JobStarted = Get-Date

    $step.startedAt = (Get-Date).ToString('o')
    $step.finishedAt = $null
    $step.error = $null
    $step.lastOp = $item.op
    if ($item.op -eq 'run') {
        $step.status = 'running'
        $step.touched = $true
        Add-TtxEvent -StepId $step.id -Message "Running: $($step.title)"
    }
    else {
        $step.status = 'cleaning'
        Add-TtxEvent -StepId $step.id -Message "Cleaning up: $($step.title)"
    }
    Save-TtxSession
}

function Complete-TtxJob {
    param([string]$TimeoutMessage)

    $job = $script:Ttx.Job
    $item = $script:Ttx.JobItem
    $step = Get-TtxStep -StepId $item.stepId

    $jobErrors = $null
    if ($TimeoutMessage) { Stop-Job -Job $job }
    $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
    $reason = $null
    if ($job.State -eq 'Failed' -and $job.ChildJobs.Count -gt 0 -and $job.ChildJobs[0].JobStateInfo.Reason) {
        $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message
    }
    Remove-Job -Job $job -Force
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null
    $script:Ttx.JobStarted = $null

    $result = $null
    $json = $out | Where-Object { $_ -is [string] -and $_.StartsWith('{') } | Select-Object -Last 1
    if ($json) {
        try { $result = ConvertFrom-TtxJson -Json $json } catch { $result = $null }
    }
    if ($null -eq $result) {
        $msg = $TimeoutMessage
        if (-not $msg) { $msg = $reason }
        if (-not $msg -and $jobErrors) { $msg = ($jobErrors | ForEach-Object { $_.ToString() }) -join '; ' }
        if (-not $msg) { $msg = 'Step runner produced no result.' }
        $result = @{ ok = $false; error = $msg; verify = $null; logs = @(); artifacts = @(); pid = $null }
    }

    foreach ($log in @($result.logs)) {
        if ($null -eq $log) { continue }
        $level = if ($log.level -in 'info', 'warn', 'error') { $log.level } else { 'info' }
        Add-TtxEvent -StepId $step.id -Level $level -Message ([string]$log.message) -Timestamp ([string]$log.ts)
    }

    $step.finishedAt = (Get-Date).ToString('o')
    $step.verify = $result.verify
    $step.error = $result.error
    $ok = [bool]$result.ok

    if ($item.op -eq 'run') {
        # What this run created or ran on the host, for the facilitator.
        $step.artifacts = @($result.artifacts | Where-Object { $null -ne $_ })
        $step.runnerPid = $result.pid
        foreach ($a in $step.artifacts) {
            Add-TtxEvent -StepId $step.id -Message "Artifact ($($a.type)): $($a.location)"
        }
        if ($ok) {
            $step.status = 'succeeded'
            Add-TtxEvent -StepId $step.id -Message "Succeeded. Verify: $($result.verify.detail)"
        }
        else {
            $step.status = 'failed'
            Add-TtxEvent -StepId $step.id -Level error -Message "Failed: $($result.error)"
            Clear-TtxRunQueue -Reason "Stopped after '$($step.id)' failed."
        }
    }
    else {
        if ($ok) {
            $step.status = 'cleaned'
            Add-TtxEvent -StepId $step.id -Message "Cleaned up. Verify: $($result.verify.detail)"
        }
        else {
            $step.status = 'cleanup-failed'
            Add-TtxEvent -StepId $step.id -Level error -Message "Cleanup failed: $($result.error)"
        }
        $moreCleanup = @($script:Ttx.Queue | Where-Object { $_.op -eq 'cleanup' }).Count -gt 0
        if (-not $moreCleanup) { Complete-TtxCleanup }
    }
    Save-TtxSession
}

# Drops queued 'run' items (e.g. Run all after a failure) and resets their steps.
function Clear-TtxRunQueue {
    param([string]$Reason)
    $dropped = @($script:Ttx.Queue | Where-Object { $_.op -eq 'run' })
    if ($dropped.Count -eq 0) { return }
    foreach ($item in $dropped) {
        [void]$script:Ttx.Queue.Remove($item)
        $step = Get-TtxStep -StepId $item.stepId
        $step.status = 'pending'
    }
    Add-TtxEvent -Level warn -Message "$Reason $($dropped.Count) queued step(s) were not run."
}

# After all cleanup operations have finished: remove the now-empty artifact
# folders and close the session if every step cleaned up.
function Complete-TtxCleanup {
    $s = $script:Ttx.Session
    $failed = @($s.steps | Where-Object { $_.status -ne 'cleaned' })
    if ($failed.Count -gt 0) {
        Add-TtxEvent -Level error -Message "Cleanup incomplete: $($failed.Count) step(s) did not clean up. Fix the cause and press Cleanup again."
        return
    }
    Remove-TtxEmptyArtifactFolders
    $s.status = 'cleaned'
    Add-TtxEvent -Message 'Cleanup complete. All artifacts removed; session closed.'
}

# Removes the session folder and any empty ArtifactFolder parents, never going
# above %ProgramData% and never deleting a folder that still has content.
function Remove-TtxEmptyArtifactFolders {
    $s = $script:Ttx.Session
    $base = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\', '/')
    $dir = [System.IO.Path]::GetFullPath($s.artifactRoot)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    while ($dir.StartsWith($base + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $children = @(Get-ChildItem -LiteralPath $dir -Force)
            if ($children.Count -gt 0) {
                if ($dir -eq [System.IO.Path]::GetFullPath($s.artifactRoot)) {
                    Add-TtxEvent -Level warn -Message "Left $dir in place: it still contains $($children.Count) item(s) the modules did not create."
                }
                break
            }
            Remove-Item -LiteralPath $dir -Force
            Add-TtxEvent -Message "Removed empty folder $dir"
        }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
}

#endregion

#region Public API

function Initialize-TtxEngine {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$StepTimeoutSec = 120
    )
    $script:Ttx.Root = $Root
    $script:Ttx.RunsDir = Join-Path $Root 'runs'
    $script:Ttx.ScenariosDir = Join-Path $Root 'scenarios'
    $script:Ttx.ModulesDir = Join-Path $Root 'modules'
    $script:Ttx.RunnerPath = Join-Path (Join-Path $Root 'server') 'StepRunner.ps1'
    $script:Ttx.StepTimeoutSec = $StepTimeoutSec
    $script:Ttx.Session = $null
    $script:Ttx.Events.Clear()
    $script:Ttx.Queue.Clear()
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null

    if (-not (Test-Path -LiteralPath $script:Ttx.RunsDir)) {
        New-Item -ItemType Directory -Path $script:Ttx.RunsDir | Out-Null
    }
    Restore-TtxSession
}

# Reloads the most recent session that has not been cleaned up, so Cleanup
# still works after the server restarts.
function Restore-TtxSession {
    $dirs = @(Get-ChildItem -LiteralPath $script:Ttx.RunsDir -Directory | Sort-Object Name -Descending)
    foreach ($dir in $dirs) {
        $statePath = Join-Path $dir.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try {
            $state = ConvertFrom-TtxJson -Json (Read-TtxTextFile -Path $statePath)
        }
        catch {
            Write-Warning "Skipping unreadable session state $statePath : $($_.Exception.Message)"
            continue
        }
        if ($state.status -ne 'active') { continue }

        $script:Ttx.Session = $state
        $eventsPath = Join-Path $dir.FullName 'events.jsonl'
        if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($eventsPath, [System.Text.Encoding]::UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $evt = ConvertFrom-TtxJson -Json $line
                    $evt.seq = $script:Ttx.Events.Count
                    [void]$script:Ttx.Events.Add($evt)
                }
                catch {
                    Write-Warning "Skipping unreadable line in $eventsPath"
                }
            }
        }
        Add-TtxEvent -Message "Server restarted; restored session $($state.sessionId)."
        foreach ($step in $state.steps) {
            if ($step.status -in 'queued', 'running', 'cleanup-queued', 'cleaning') {
                $step.status = 'interrupted'
                Add-TtxEvent -StepId $step.id -Level warn -Message 'Was in progress when the server stopped; marked interrupted. Run Cleanup to be safe.'
            }
        }
        Save-TtxSession
        return
    }
}

function New-TtxSession {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioId,
        [hashtable]$Parameters = @{}
    )
    if (Test-TtxBusy) { throw (New-TtxConflict 'A step is running. Wait for it to finish or press Cleanup.') }
    $current = $script:Ttx.Session
    if ($current -and $current.status -eq 'active' -and (Test-TtxSessionTouched)) {
        throw (New-TtxConflict "Session $($current.sessionId) has steps that ran. Press Cleanup before loading another scenario.")
    }
    if ($ScenarioId -notmatch $script:IdPattern) { throw (New-TtxBadRequest 'Invalid scenario id.') }
    $entry = Read-TtxScenario -FolderName $ScenarioId
    if ($null -eq $entry) { throw (New-TtxNotFound "Scenario '$ScenarioId' not found.") }
    if ($entry.errors.Count -gt 0) { throw (New-TtxBadRequest ("Scenario '$ScenarioId' is invalid: " + ($entry.errors -join ' '))) }
    $scenario = $entry.scenario

    # Resolve parameters: given value, else scenario default. Unknown names are ignored.
    $resolved = @{}
    foreach ($p in (Get-TtxScenarioParameters -Scenario $scenario)) {
        $value = $p.default
        if ($Parameters -and $Parameters.ContainsKey($p.name) -and -not [string]::IsNullOrWhiteSpace([string]$Parameters[$p.name])) {
            $value = ([string]$Parameters[$p.name]).Trim()
        }
        $resolved[$p.name] = $value
    }
    $folder = [string]$resolved.ArtifactFolder
    if ($folder -notmatch $script:FolderPattern -or $folder -match '(^|[\\/])\.\.?([\\/]|$)') {
        throw (New-TtxBadRequest "ArtifactFolder '$folder' must be a relative folder path (letters, digits, space, . _ -) with no '..'.")
    }
    if ([string]::IsNullOrEmpty($env:ProgramData)) { throw 'The ProgramData environment variable is not set.' }

    $sessionId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $artifactRoot = Join-Path (Join-Path $env:ProgramData $folder) $sessionId

    if ($current -and $current.status -eq 'active') {
        $current.status = 'abandoned'
        Add-TtxEvent -Message 'Session replaced before any step ran.'
        Save-TtxSession
    }

    $steps = @(foreach ($st in @($scenario.steps | Where-Object { $null -ne $_ })) {
            @{
                id               = [string]$st.id
                title            = [string]$st.title
                module           = [string]$st.module
                params           = if ($st.params -is [hashtable]) { $st.params } else { @{} }
                facilitatorNotes = @($st.facilitatorNotes | Where-Object { $_ } | ForEach-Object { [string]$_ })
                info             = $null
                hunt             = @()
                describeError    = $null
                status           = 'pending'
                touched          = $false
                artifacts        = @()
                runnerPid        = $null
                lastOp           = $null
                verify           = $null
                error            = $null
                startedAt        = $null
                finishedAt       = $null
            }
        })

    $script:Ttx.Events.Clear()
    $script:Ttx.Session = @{
        schemaVersion   = 1
        sessionId       = $sessionId
        scenarioId      = [string]$scenario.id
        scenarioName    = [string]$scenario.name
        scenarioSummary = [string]$scenario.summary
        objectives      = @($scenario.objectives | Where-Object { $_ } | ForEach-Object { [string]$_ })
        createdAt       = (Get-Date).ToString('o')
        updatedAt       = $null
        status          = 'active'
        parameters      = $resolved
        artifactRoot    = $artifactRoot
        steps           = $steps
    }
    New-Item -ItemType Directory -Path (Get-TtxSessionDir) -Force | Out-Null
    Save-TtxSession
    Add-TtxEvent -Message "Session $sessionId created for scenario '$($scenario.name)'. Artifacts go to $artifactRoot"

    foreach ($step in $steps) {
        $d = Invoke-TtxDescribe -Step $step
        if ($d.ok) {
            $step.info = $d.info
            $step.hunt = @($d.hunt)
        }
        else {
            $step.describeError = $d.error
            Add-TtxEvent -StepId $step.id -Level error -Message "Could not load module '$($step.module)': $($d.error)"
        }
    }
    Save-TtxSession
    return (Get-TtxSessionView)
}

function Get-TtxSessionView {
    param([int]$Since = 0)
    $count = $script:Ttx.Events.Count
    if ($Since -lt 0 -or $Since -gt $count) { $Since = 0 }
    $current = $null
    if ($script:Ttx.JobItem) { $current = $script:Ttx.JobItem }
    return @{
        session    = $script:Ttx.Session
        busy       = (Test-TtxBusy)
        current    = $current
        eventCount = $count
        events     = @($script:Ttx.Events.GetRange($Since, $count - $Since))
    }
}

function Assert-TtxCanRun {
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    if ($s.status -ne 'active') { throw (New-TtxConflict 'This session is closed. Load a scenario to start a new one.') }
    if (Test-TtxBusy) { throw (New-TtxConflict 'A step is already running.') }
}

function Start-TtxStep {
    param([Parameter(Mandatory = $true)][string]$StepId)
    Assert-TtxCanRun
    $step = Get-TtxStep -StepId $StepId
    if (-not $step) { throw (New-TtxNotFound "Step '$StepId' not found.") }
    $step.status = 'queued'
    [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'run' })
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

function Start-TtxRunAll {
    Assert-TtxCanRun
    foreach ($step in $script:Ttx.Session.steps) {
        $step.status = 'queued'
        [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'run' })
    }
    Add-TtxEvent -Message "Run all: $($script:Ttx.Session.steps.Count) step(s) queued."
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

# Stops anything in progress, then cleans up every step in reverse order.
# Cleanup is idempotent, so it runs for all steps, not just the ones that ran.
function Start-TtxCleanup {
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    if ($s.status -ne 'active') { throw (New-TtxConflict 'This session is already closed.') }
    if (@($script:Ttx.Queue | Where-Object { $_.op -eq 'cleanup' }).Count -gt 0 -or
        ($script:Ttx.JobItem -and $script:Ttx.JobItem.op -eq 'cleanup')) {
        throw (New-TtxConflict 'Cleanup is already in progress.')
    }

    Stop-TtxCurrentJob -Reason 'Stopped for cleanup.'
    Clear-TtxRunQueue -Reason 'Cleanup requested.'

    Add-TtxEvent -Message 'Cleanup started (steps in reverse order).'
    $steps = @($s.steps)
    [array]::Reverse($steps)
    foreach ($step in $steps) {
        $step.status = 'cleanup-queued'
        [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'cleanup' })
    }
    Save-TtxSession
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

function Stop-TtxCurrentJob {
    param([string]$Reason)
    if (-not $script:Ttx.Job) { return }
    $step = Get-TtxStep -StepId $script:Ttx.JobItem.stepId
    Stop-Job -Job $script:Ttx.Job
    Remove-Job -Job $script:Ttx.Job -Force
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null
    $script:Ttx.JobStarted = $null
    $step.status = 'interrupted'
    $step.finishedAt = (Get-Date).ToString('o')
    Add-TtxEvent -StepId $step.id -Level warn -Message "Interrupted. $Reason"
}

# Called from the server loop: collects a finished job, enforces the timeout,
# and starts the next queued operation.
function Update-TtxEngine {
    if ($script:Ttx.Job) {
        $state = $script:Ttx.Job.State
        if ($state -in 'Completed', 'Failed', 'Stopped') {
            Complete-TtxJob
        }
        elseif (((Get-Date) - $script:Ttx.JobStarted).TotalSeconds -gt $script:Ttx.StepTimeoutSec) {
            Complete-TtxJob -TimeoutMessage "Timed out after $($script:Ttx.StepTimeoutSec) seconds."
        }
    }
    Start-TtxNextJob
}

# Called when the server shuts down.
function Stop-TtxEngine {
    if ($script:Ttx.Session -and (Test-TtxBusy)) {
        Stop-TtxCurrentJob -Reason 'Server is shutting down.'
        foreach ($item in @($script:Ttx.Queue)) {
            $step = Get-TtxStep -StepId $item.stepId
            if ($step.status -in 'queued', 'cleanup-queued') { $step.status = 'interrupted' }
        }
        $script:Ttx.Queue.Clear()
        Save-TtxSession
    }
}

#endregion

Export-ModuleMember -Function Initialize-TtxEngine, Get-TtxScenarioList, New-TtxSession, Get-TtxSessionView,
    Start-TtxStep, Start-TtxRunAll, Start-TtxCleanup, Update-TtxEngine, Stop-TtxEngine,
    ConvertFrom-TtxJson, ConvertTo-TtxJson
