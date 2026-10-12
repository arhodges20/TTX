# STUB module: the scheduled task fires and runs the stand-in script.
# Only logs and writes/removes a marker file. Nothing is executed.

function Get-TtxModuleInfo {
    @{
        Id          = 'stub-task-execution'
        Name        = 'Scheduled task fires (STUB)'
        Description = 'Stub for the task trigger firing and the stand-in script running. Writes a marker file only.'
        Version     = '0.1.0'
        Technique   = 'T1053.005'
        IsStub      = $true
        Parameters  = @()
    }
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    Write-TtxLog -Message 'STUB: a real module would simulate the task firing and the stand-in script writing its own marker. Nothing is executed.'
    New-TtxMarker -Context $Context -Description 'Stand-in for the stand-in script having run from the scheduled task.' | Out-Null
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if (Test-TtxMarker -Context $Context) {
        @{ Passed = $true; Detail = 'Execution marker is present.' }
    }
    else {
        @{ Passed = $false; Detail = 'Execution marker is absent.' }
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
            Title = 'Task run history'
            Where = 'Microsoft-Windows-TaskScheduler/Operational Event IDs 100, 200, 201'
            What  = 'Runs of newly created tasks, and the action path each one launched.'
        },
        @{
            Title = 'Process lineage'
            Where = 'Process creation (Sysmon Event ID 1, Security 4688)'
            What  = 'powershell.exe or script hosts whose parent is svchost.exe (Schedule service) or taskeng.exe, running a script from ProgramData.'
        }
    )
}
