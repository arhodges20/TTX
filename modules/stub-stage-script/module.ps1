# STUB module: stage a stand-in script.
# Only logs and writes/removes a marker file. No script is written or run.

function Get-TtxModuleInfo {
    @{
        Id          = 'stub-stage-script'
        Name        = 'Stage stand-in script (STUB)'
        Description = 'Stub for dropping a stand-in script that a scheduled task would later launch. Writes a marker file only.'
        Version     = '0.1.0'
        Technique   = ''
        IsStub      = $true
        Parameters  = @(
            @{ Name = 'ScriptName'; Default = 'ttx-updater.ps1'; Description = 'File name the real module would give the stand-in script.' }
        )
    }
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $scriptName = $Context.Parameters.ScriptName
    Write-TtxLog -Message "STUB: a real module would stage stand-in script '$scriptName' in $($Context.ArtifactRoot)."
    New-TtxMarker -Context $Context -Description "Stand-in for staged script '$scriptName'." | Out-Null
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if (Test-TtxMarker -Context $Context) {
        @{ Passed = $true; Detail = 'Staging marker is present.' }
    }
    else {
        @{ Passed = $false; Detail = 'Staging marker is absent.' }
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
            Title = 'New script files in ProgramData'
            Where = 'File creation telemetry (Sysmon Event ID 11, EDR file events) under C:\ProgramData'
            What  = 'Script files (.ps1, .bat, .vbs) created in ProgramData by an interactive user or an unusual parent process.'
        }
    )
}
