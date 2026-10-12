# STUB module: register a scheduled task for persistence.
# Only logs and writes/removes a marker file. No scheduled task is created.

function Get-TtxModuleInfo {
    @{
        Id          = 'stub-register-scheduled-task'
        Name        = 'Register scheduled task (STUB)'
        Description = 'Stub for registering a scheduled task that launches the stand-in script. Writes a marker file only; does NOT create a task.'
        Version     = '0.1.0'
        Technique   = 'T1053.005'
        IsStub      = $true
        Parameters  = @(
            @{ Name = 'TaskName'; Default = 'TTX-Lab-Updater'; Description = 'Name the real module would give the scheduled task.' },
            @{ Name = 'Trigger'; Default = 'AtLogOn'; Description = 'Trigger the real module would use.' }
        )
    }
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $taskName = $Context.Parameters.TaskName
    $trigger = $Context.Parameters.Trigger
    Write-TtxLog -Message "STUB: a real module would register scheduled task '$taskName' with trigger '$trigger'. No task is created."
    New-TtxMarker -Context $Context -Description "Stand-in for scheduled task '$taskName' (trigger: $trigger)." | Out-Null
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if (Test-TtxMarker -Context $Context) {
        @{ Passed = $true; Detail = 'Scheduled-task marker is present.' }
    }
    else {
        @{ Passed = $false; Detail = 'Scheduled-task marker is absent.' }
    }
}

function Invoke-TtxCleanup {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    Remove-TtxMarker -Context $Context
}

function Get-TtxHunt {
    param([hashtable]$Context)
    @(
        @{
            Title = 'Task registration events'
            Where = 'Security log Event ID 4698 (needs "Audit Other Object Access Events"); Microsoft-Windows-TaskScheduler/Operational Event ID 106'
            What  = 'New tasks registered by a user account, especially with logon or startup triggers.'
        },
        @{
            Title = 'Task definitions on disk'
            Where = 'C:\Windows\System32\Tasks and HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache'
            What  = 'Recently created task XML whose action runs powershell.exe, cmd.exe, or a script from a user-writable path such as ProgramData.'
        },
        @{
            Title = 'Task creation tooling'
            Where = 'Process creation (Security 4688 with command line, Sysmon Event ID 1)'
            What  = 'schtasks.exe /create or PowerShell Register-ScheduledTask run interactively.'
        }
    )
}
