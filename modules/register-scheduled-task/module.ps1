# Registers a real scheduled task whose action runs the staged stand-in
# script. The task description tags it with the session id; Cleanup only ever
# removes a task carrying that tag.

function Get-TtxModuleInfo {
    @{
        Id          = 'register-scheduled-task'
        Name        = 'Register scheduled task'
        Description = 'Registers a scheduled task (logon trigger, current user) whose action runs the stand-in script with powershell.exe.'
        Version     = '1.1.0'
        Technique   = 'T1053.005'
        Tactic      = 'Persistence'
        IsStub      = $false
        Parameters  = @(
            @{ Name = 'ScriptName'; Default = 'updater.ps1'; Description = 'Script the task runs (from the stage step).' },
            @{ Name = 'TaskName'; Default = 'TTX-Lab-Updater'; Description = 'Name of the scheduled task.' },
            @{ Name = 'TaskPath'; Default = '\'; Description = 'Task Scheduler folder for the task.' }
        )
        ExpectedDetections = @(
            @{ Id = 'scheduled-task-persistence'; Tactic = 'Persistence'; Technique = 'T1053.005'; Description = 'Scheduled task created for persistence (logon trigger running PowerShell from ProgramData)' }
        )
    }
}

function Get-TtxTaskTag {
    param([hashtable]$Context)
    return "TTX Control Center benign exercise task. Session $($Context.SessionId). Safe to delete."
}

function Get-TtxTaskPath {
    param([hashtable]$Context)
    $taskPath = [string]$Context.Parameters.TaskPath
    if ([string]::IsNullOrEmpty($taskPath)) { $taskPath = '\' }
    if (-not $taskPath.StartsWith('\')) { $taskPath = '\' + $taskPath }
    if (-not $taskPath.EndsWith('\')) { $taskPath = $taskPath + '\' }
    return $taskPath
}

# Returns the task only if this session created it (its description carries
# the session tag). A same-named task that isn't ours is never returned.
function Get-TtxOwnedTask {
    param([hashtable]$Context)
    $task = Get-ScheduledTask -TaskPath (Get-TtxTaskPath $Context) -TaskName ([string]$Context.Parameters.TaskName) -ErrorAction SilentlyContinue
    if ($task -and $task.Description -eq (Get-TtxTaskTag $Context)) { return $task }
    return $null
}

function Test-TtxForeignTask {
    param([hashtable]$Context)
    $task = Get-ScheduledTask -TaskPath (Get-TtxTaskPath $Context) -TaskName ([string]$Context.Parameters.TaskName) -ErrorAction SilentlyContinue
    return ($task -and $task.Description -ne (Get-TtxTaskTag $Context))
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $taskName = [string]$Context.Parameters.TaskName
    if ($taskName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*$') { throw "TaskName '$taskName' is invalid." }
    $taskPath = Get-TtxTaskPath $Context
    $script = Get-TtxArtifactPath -Context $Context -Name ([string]$Context.Parameters.ScriptName)
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Script $script not found. Run the stage step first."
    }

    if (Test-TtxForeignTask $Context) {
        throw "A scheduled task '$taskPath$taskName' already exists and was not created by this session. Not touching it; load the scenario with another TaskName."
    }
    if (Get-TtxOwnedTask $Context) {
        Write-TtxLog -Message 'Task from an earlier run of this step exists; re-registering it.'
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
    }

    $user = "$env:USERDOMAIN\$env:USERNAME"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Description (Get-TtxTaskTag $Context) | Out-Null

    Write-TtxLog -Message "Registered scheduled task $taskPath$taskName (at logon of $user)."
    Register-TtxArtifact -Type scheduled-task -Location "$taskPath$taskName" `
        -Detail "Trigger: at logon of $user. Action: powershell.exe $arguments"
    Register-TtxArtifact -Type file -Location "$env:SystemRoot\System32\Tasks$taskPath$taskName" `
        -Detail 'Task definition XML written by the Task Scheduler service.'
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $name = "$(Get-TtxTaskPath $Context)$($Context.Parameters.TaskName)"
    if (Get-TtxOwnedTask $Context) {
        @{ Passed = $true; Detail = "Scheduled task $name is registered." }
    }
    else {
        @{ Passed = $false; Detail = "Scheduled task $name is not registered." }
    }
}

function Invoke-TtxCleanup {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $taskPath = Get-TtxTaskPath $Context
    $taskName = [string]$Context.Parameters.TaskName
    if (Get-TtxOwnedTask $Context) {
        Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
        Write-TtxLog -Message "Unregistered scheduled task $taskPath$taskName."
    }
    elseif (Test-TtxForeignTask $Context) {
        Write-TtxLog -Level warn -Message "A scheduled task $taskPath$taskName exists but was not created by this session; leaving it alone."
    }
    else {
        Write-TtxLog -Message "Scheduled task $taskPath$taskName already absent."
    }
}

function Get-TtxHunt {
    param([hashtable]$Context)
    @{
        Lineage = @(
            'powershell.exe (TTX job) -> powershell.exe (Register-ScheduledTask) registers the task',
            'The registered action: powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {{ArtifactRoot}}\{{ScriptName}}'
        )
        FalconEvents = @(
            @{ Name = 'ScheduledTaskRegistered'; Detail = 'New task {{TaskName}} with a logon trigger; confirm in your tenant.' },
            @{ Name = 'ProcessRollup2'; Detail = 'The powershell.exe that registered the task, its parent and user.' }
        )
        WindowsEvidence = @(
            @{ Name = 'Security 4698'; Detail = 'Task created (needs "Audit Other Object Access Events").' },
            @{ Name = 'TaskScheduler/Operational 106'; Detail = 'Task registered.' },
            @{ Name = 'Task XML'; Detail = 'C:\Windows\System32\Tasks\{{TaskName}} - author, trigger, exact command line.' }
        )
        Queries = @(
            @{ Title = 'Task registration on this host'; Query = '#event_simpleName=ScheduledTaskRegistered aid={{Aid}} TaskName=/{{TaskName}}/i' }
        )
        Pivots = @(
            'From the task action, find the script path {{ArtifactRoot}}\{{ScriptName}}, then who wrote it (stage step), then how that process got there.'
        )
    }
}
