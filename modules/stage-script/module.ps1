# Stages a benign stand-in script in the session's artifact folder.
# The script only appends one line (time, user, host) to a log file next to
# itself. It is launched later by the scheduled task.

function Get-TtxModuleInfo {
    @{
        Id          = 'stage-script'
        Name        = 'Stage stand-in script'
        Description = 'Writes a benign PowerShell script to the artifact folder. When run, the script only appends one line to a .log file beside it.'
        Version     = '1.0.0'
        Technique   = ''
        IsStub      = $false
        Parameters  = @(
            @{ Name = 'ScriptName'; Default = 'updater.ps1'; Description = 'File name of the stand-in script.' }
        )
    }
}

function Get-TtxScriptLogName {
    param([string]$ScriptName)
    return ([System.IO.Path]::GetFileNameWithoutExtension($ScriptName) + '.log')
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $scriptName = [string]$Context.Parameters.ScriptName
    if ($scriptName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$') {
        throw "ScriptName '$scriptName' must be a simple .ps1 file name."
    }
    $logName = Get-TtxScriptLogName -ScriptName $scriptName
    $content = @(
        '# TTX Control Center: benign stand-in script for a tabletop exercise.'
        "# Session $($Context.SessionId). Safe to delete; TTX Control Center Cleanup removes it."
        '# It only appends one line (time, user, computer) to a log file next to itself.'
        "`$log = Join-Path `$PSScriptRoot '$logName'"
        "`$line = '{0} ran as {1} on {2}' -f (Get-Date).ToString('o'), [Environment]::UserName, `$env:COMPUTERNAME"
        'Add-Content -LiteralPath $log -Value $line'
    ) -join "`r`n"
    New-TtxArtifactFile -Context $Context -Name $scriptName -Content ($content + "`r`n") `
        -Detail "Benign stand-in script. When run it appends a line to $logName." | Out-Null
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $scriptName = [string]$Context.Parameters.ScriptName
    if (Test-TtxArtifactFile -Context $Context -Name $scriptName) {
        @{ Passed = $true; Detail = "Script $scriptName is present." }
    }
    else {
        @{ Passed = $false; Detail = "Script $scriptName is absent." }
    }
}

function Invoke-TtxCleanup {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    Remove-TtxArtifactFile -Context $Context -Name ([string]$Context.Parameters.ScriptName)
}

function Get-TtxHunt {
    param([hashtable]$Context)
    @(
        @{
            Title = 'Script written to ProgramData'
            Where = 'Falcon: NewScriptWritten events; file write telemetry for C:\ProgramData'
            What  = 'A new .ps1 file under C:\ProgramData written by powershell.exe. Note the folder and file name for the next steps.'
        },
        @{
            Title = 'Who wrote it'
            Where = 'Falcon process tree for the writing process (ProcessRollup2)'
            What  = 'The powershell.exe that wrote the file, its parent process and command line, and the user account.'
        }
    )
}
