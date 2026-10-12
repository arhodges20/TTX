# Starts the registered scheduled task once, so the Task Scheduler launches
# powershell.exe -> stand-in script, which appends a line to its log file.

function Get-TtxModuleInfo {
    @{
        Id          = 'run-scheduled-task'
        Name        = 'Scheduled task runs'
        Description = 'Starts the scheduled task now (as a logon would). The Task Scheduler launches powershell.exe, which runs the stand-in script; the script appends a line to its log file.'
        Version     = '1.0.0'
        Technique   = 'T1053.005'
        IsStub      = $false
        Parameters  = @(
            @{ Name = 'ScriptName'; Default = 'updater.ps1'; Description = 'Script the task runs.' },
            @{ Name = 'TaskName'; Default = 'TTX-Lab-Updater'; Description = 'Name of the scheduled task.' },
            @{ Name = 'TaskPath'; Default = '\'; Description = 'Task Scheduler folder for the task.' },
            @{ Name = 'WaitSeconds'; Default = 30; Description = 'How long to wait for the script to write its log.' }
        )
    }
}

function Get-TtxRunInfo {
    param([hashtable]$Context)
    $taskPath = [string]$Context.Parameters.TaskPath
    if ([string]::IsNullOrEmpty($taskPath)) { $taskPath = '\' }
    if (-not $taskPath.StartsWith('\')) { $taskPath = '\' + $taskPath }
    if (-not $taskPath.EndsWith('\')) { $taskPath = $taskPath + '\' }
    $scriptName = [string]$Context.Parameters.ScriptName
    return @{
        TaskPath = $taskPath
        TaskName = [string]$Context.Parameters.TaskName
        Script   = Get-TtxArtifactPath -Context $Context -Name $scriptName
        LogName  = [System.IO.Path]::GetFileNameWithoutExtension($scriptName) + '.log'
    }
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $r = Get-TtxRunInfo $Context
    $task = Get-ScheduledTask -TaskPath $r.TaskPath -TaskName $r.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { throw "Scheduled task $($r.TaskPath)$($r.TaskName) not found. Run the register step first." }
    if ($task.Description -notlike "*Session $($Context.SessionId).*") {
        throw "Scheduled task $($r.TaskPath)$($r.TaskName) was not created by this session; not starting it."
    }

    $logPath = Get-TtxArtifactPath -Context $Context -Name $r.LogName
    $before = 0
    if (Test-Path -LiteralPath $logPath -PathType Leaf) { $before = (Get-Item -LiteralPath $logPath).Length }

    Start-ScheduledTask -TaskPath $r.TaskPath -TaskName $r.TaskName
    Write-TtxLog -Message "Started scheduled task $($r.TaskPath)$($r.TaskName); waiting for the script to write $logPath."

    $deadline = (Get-Date).AddSeconds([int]$Context.Parameters.WaitSeconds)
    $written = $false
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and (Get-Item -LiteralPath $logPath).Length -gt $before) {
            $written = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $written) {
        $info = Get-ScheduledTaskInfo -TaskPath $r.TaskPath -TaskName $r.TaskName -ErrorAction SilentlyContinue
        throw "The script did not write $logPath within $($Context.Parameters.WaitSeconds) s. Task last result: $($info.LastTaskResult). The EDR may have blocked it; check the Falcon console."
    }

    $line = @(Get-Content -LiteralPath $logPath) | Select-Object -Last 1
    Write-TtxLog -Message "Script ran: $line"
    Register-TtxArtifact -Type process -Location 'powershell.exe' `
        -Detail "Launched by the Task Scheduler (svchost.exe, Schedule service): powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($r.Script)`""
    Register-TtxArtifact -Type file -Location $logPath -Detail "Written by the stand-in script: $line"
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $r = Get-TtxRunInfo $Context
    if (Test-TtxArtifactFile -Context $Context -Name $r.LogName) {
        @{ Passed = $true; Detail = "Script log $($r.LogName) is present." }
    }
    else {
        @{ Passed = $false; Detail = "Script log $($r.LogName) is absent." }
    }
}

function Invoke-TtxCleanup {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $r = Get-TtxRunInfo $Context
    Remove-TtxArtifactFile -Context $Context -Name $r.LogName
}

function Get-TtxHunt {
    param([hashtable]$Context)
    @(
        @{
            Title = 'Task-launched PowerShell'
            Where = 'Falcon process tree (ProcessRollup2): parent svchost.exe (Schedule service)'
            What  = 'powershell.exe with -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\...\*.ps1, launched by the Task Scheduler rather than by a user.'
        },
        @{
            Title = 'Task run history'
            Where = 'Windows: Microsoft-Windows-TaskScheduler/Operational 100, 129, 200, 201'
            What  = 'The task starting, the process it created, and its completion; matches the Falcon process timestamps.'
        },
        @{
            Title = 'What the script did'
            Where = 'Falcon file write telemetry; the folder the script lives in'
            What  = 'A .log file written next to the script, by the task-launched powershell.exe.'
        }
    )
}
