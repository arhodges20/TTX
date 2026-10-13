<#
.SYNOPSIS
    Runs one Atomic Red Team operation for one scenario step and writes one
    JSON result string.

.DESCRIPTION
    The engine runs this in a background job (a separate powershell.exe). It
    imports the ART module by path and calls Invoke-AtomicTest for the step's
    test GUID. This script adds no attack behavior: what runs is the installed
    atomic (decision D19).

    Operations:
      run         -CheckPrereqs; if prereqs are missing, stop and report them.
                  Otherwise execute with the step's input arguments and a
                  per-run -ExecutionLogPath, then run the step's verify checks.
      getprereqs  -GetPrereqs (the engine only queues this after the admin
                  confirmed), then -CheckPrereqs again.
      cleanup     -Cleanup, then the verify checks again: anything that passed
                  after the run and still passes is reported as remaining.

    Result: { ok, error, op, prereqs, run, verify, getPrereqs, cleanup, pid }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('run', 'getprereqs', 'cleanup')][string]$Operation,
    [Parameter(Mandatory = $true)][string]$ContextJson
)

$ErrorActionPreference = 'Stop'
$MaxOutputChars = 20000

$result = @{
    ok         = $false
    error      = $null
    op         = $Operation
    prereqs    = $null
    run        = $null
    verify     = @()
    getPrereqs = $null
    cleanup    = $null
    pid        = $PID
}

# ART runs in its own runspace. PowerShell lets any try/catch up the call
# stack catch errors that would otherwise only end one statement, so calling
# ART from inside this script's try block would abort a test on a harmless
# error (e.g. a logger hiccup). In a separate runspace ART runs with
# PowerShell's default error handling, as it does from a console.
$script:TtxArtRunspace = $null

function Open-TtxArtRunspace {
    param([Parameter(Mandatory = $true)][string]$ModulePath)
    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        throw "ART module not found at $ModulePath. Install Invoke-AtomicRedTeam there or set the ART root."
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    try {
        # Runs in the runspace's global scope, so ART's classes are visible.
        [void]$ps.AddScript('param($Path) Import-Module -Name $Path -Force -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop').AddArgument($ModulePath)
        try { [void]$ps.Invoke() }
        catch { throw "Could not import the ART module from $ModulePath : $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
        if ($ps.HadErrors) {
            throw "Could not import the ART module from $ModulePath : $(($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')"
        }
    }
    finally { $ps.Dispose() }
    $script:TtxArtRunspace = $rs
}

# Runs Invoke-AtomicTest with the step's test and input arguments plus the
# given switches, and returns every output line (ART writes with Write-Host).
function Invoke-TtxAtomic {
    param([hashtable]$Ctx, [hashtable]$Extra)
    $splat = @{
        AtomicTechnique     = [string]$Ctx.technique
        TestGuids           = @([string]$Ctx.guid)
        PathToAtomicsFolder = [string]$Ctx.atomicsPath
        TimeoutSeconds      = [int]$Ctx.timeoutSeconds
    }
    if ($Ctx.inputArgs -is [hashtable] -and $Ctx.inputArgs.Count -gt 0) {
        $ia = @{}
        foreach ($k in @($Ctx.inputArgs.Keys)) { $ia[$k] = [string]$Ctx.inputArgs[$k] }
        $splat.InputArgs = $ia
    }
    foreach ($k in @($Extra.Keys)) { $splat[$k] = $Extra[$k] }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $script:TtxArtRunspace
    $lines = New-Object System.Collections.ArrayList
    try {
        [void]$ps.AddScript('param($Splat) Invoke-AtomicTest @Splat *>&1').AddArgument($splat)
        $out = @()
        try { $out = @($ps.Invoke()) }
        catch { [void]$lines.Add("ERROR: $($_.Exception.Message)") }
        foreach ($o in $out) {
            if ($o -is [System.Management.Automation.ErrorRecord]) { [void]$lines.Add("ERROR: $($o.ToString())") }
            elseif ($o -is [System.Management.Automation.InformationRecord]) { [void]$lines.Add([string]$o.MessageData) }
            else { [void]$lines.Add([string]$o) }
        }
        foreach ($e in @($ps.Streams.Error)) { [void]$lines.Add("ERROR: $($e.ToString())") }
    }
    finally { $ps.Dispose() }
    return , @($lines)
}

function Format-TtxOutput {
    param([string[]]$Lines)
    $text = ($Lines -join "`n").Trim()
    if ($text.Length -gt $MaxOutputChars) {
        $text = "[... output truncated, last $MaxOutputChars characters ...]`n" + $text.Substring($text.Length - $MaxOutputChars)
    }
    return $text
}

# Parses ART's CheckPrereqs output ("Prerequisites met:" / "Prerequisites not
# met:" followed by "[*] <reason>" lines).
function Get-TtxPrereqStatus {
    param([hashtable]$Ctx)
    $lines = Invoke-TtxAtomic -Ctx $Ctx -Extra @{ CheckPrereqs = $true }
    $text = $lines -join "`n"
    $status = 'unknown'
    if ($text -match 'Prerequisites not met') { $status = 'missing' }
    elseif ($text -match 'Prerequisites met') { $status = 'met' }
    $missing = @()
    foreach ($m in [regex]::Matches($text, '\[\*\]\s*([^\r\n\t]+)')) {
        $reason = $m.Groups[1].Value.Trim()
        if ($reason) { $missing += $reason }
    }
    return @{ status = $status; missing = $missing; output = (Format-TtxOutput $lines); checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
}

function Read-TtxExecutionLog {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try { Import-Csv -LiteralPath $Path } catch { return }
}

try {
    . (Join-Path $PSScriptRoot 'TtxCommon.ps1')
    . (Join-Path $PSScriptRoot 'Art.ps1')
    . (Join-Path $PSScriptRoot 'Verify.ps1')
    . (Join-Path $PSScriptRoot 'Preflight.ps1')

    $ctx = ConvertFrom-TtxJson -Json $ContextJson
    if ($ctx.values -isnot [hashtable]) { $ctx.values = @{} }
    if ($ctx.inputArgs -isnot [hashtable]) { $ctx.inputArgs = @{} }
    if (-not $ctx.timeoutSeconds) { $ctx.timeoutSeconds = 120 }

    Open-TtxArtRunspace -ModulePath ([string]$ctx.modulePath)

    if ($ctx.elevationRequired -and -not (Test-TtxIsElevated)) {
        throw 'This atomic requires elevation and the control center is not elevated.'
    }

    switch ($Operation) {
        'run' {
            $result.prereqs = Get-TtxPrereqStatus -Ctx $ctx
            if ($result.prereqs.status -eq 'missing') {
                $result.error = 'Prerequisites not met: ' + ($result.prereqs.missing -join '; ')
                break
            }

            $logPath = [string]$ctx.executionLogPath
            $before = @(Read-TtxExecutionLog $logPath).Count
            $start = (Get-Date).ToUniversalTime()
            $extra = @{}
            if ($logPath) { $extra.ExecutionLogPath = $logPath }
            $lines = Invoke-TtxAtomic -Ctx $ctx -Extra $extra
            $end = (Get-Date).ToUniversalTime()
            $text = $lines -join "`n"

            # Exit code: the execution-log row ART wrote for this test, else the
            # "Exit code: N" line ART prints after running the command.
            $exitCode = $null
            $source = $null
            $rows = @(Read-TtxExecutionLog $logPath)
            $new = @()
            if ($rows.Count -gt $before) { $new = @($rows[$before..($rows.Count - 1)] | Where-Object { [string]$_.GUID -eq [string]$ctx.guid }) }
            if ($new.Count -gt 0) {
                $row = $new[-1]
                if ($row.PSObject.Properties['ExitCode'] -and [string]$row.ExitCode -match '^-?\d+$') {
                    $exitCode = [int]$row.ExitCode
                    $source = 'execution log'
                }
            }
            if ($null -eq $exitCode) {
                $ms = [regex]::Matches($text, 'Exit code:\s*(-?\d+)')
                if ($ms.Count -gt 0) { $exitCode = [int]$ms[$ms.Count - 1].Groups[1].Value; $source = 'ART output' }
            }
            $executed = ($new.Count -gt 0) -or ($text -match 'Executing test:')

            $result.run = @{
                startUtc       = $start.ToString('o')
                endUtc         = $end.ToString('o')
                exitCode       = $exitCode
                exitCodeSource = $source
                executed       = $executed
                output         = (Format-TtxOutput $lines)
                logPath        = $logPath
            }
            $result.verify = Invoke-TtxVerifyChecks -Checks $ctx.verify -Values $ctx.values -StepStartUtc ([string]$ctx.stepStartUtc)

            if (-not $executed) {
                $result.error = 'ART did not run the test. Check that the GUID exists in the installed atomics and supports Windows.'
            }
            elseif ($null -ne $exitCode -and $exitCode -ne 0) {
                $result.error = "The atomic exited with code $exitCode."
            }
            else {
                $failed = @($result.verify | Where-Object { $_.result -eq 'fail' })
                if ($failed.Count -gt 0) {
                    $result.error = 'Verify failed: ' + (($failed | ForEach-Object { "$($_.type) $($_.target)" }) -join '; ')
                }
                else { $result.ok = $true }
            }
        }
        'getprereqs' {
            $lines = Invoke-TtxAtomic -Ctx $ctx -Extra @{ GetPrereqs = $true }
            $result.getPrereqs = @{ output = (Format-TtxOutput $lines); ranAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            $result.prereqs = Get-TtxPrereqStatus -Ctx $ctx
            if ($result.prereqs.status -eq 'missing') {
                $result.error = 'Prerequisites still not met: ' + ($result.prereqs.missing -join '; ')
            }
            else { $result.ok = $true }
        }
        'cleanup' {
            $output = ''
            if ($ctx.hasCleanup) {
                $lines = Invoke-TtxAtomic -Ctx $ctx -Extra @{ Cleanup = $true }
                $output = Format-TtxOutput $lines
                if (($lines -join "`n") -notmatch 'Done executing cleanup') {
                    throw "ART did not run the cleanup. Output: $output"
                }
            }
            else {
                $output = 'This atomic defines no cleanup command; nothing to run.'
            }
            $after = Invoke-TtxVerifyChecks -Checks $ctx.verify -Values $ctx.values -StepStartUtc ([string]$ctx.stepStartUtc)
            # An artifact is "remaining" if its check passed after the run and
            # still passes. A process having run is history, not an artifact.
            $previous = @($ctx.previousVerify)
            $remaining = @()
            for ($i = 0; $i -lt $after.Count; $i++) {
                $now = $after[$i]
                if ($now.type -eq 'process_ran_since_step_start') { continue }
                $was = if ($i -lt $previous.Count) { $previous[$i] } else { $null }
                if ($now.result -eq 'pass' -and ($null -eq $was -or $was.result -eq 'pass')) { $remaining += , $now }
            }
            $result.verify = $after
            $result.cleanup = @{ output = $output; remaining = $remaining; ranAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            if ($remaining.Count -gt 0) {
                $result.error = 'Still present after cleanup: ' + (($remaining | ForEach-Object { "$($_.type) $($_.target)" }) -join '; ')
            }
            else { $result.ok = $true }
        }
    }
}
catch {
    $result.ok = $false
    $result.error = $_.Exception.Message
}
finally {
    if ($script:TtxArtRunspace) { $script:TtxArtRunspace.Dispose() }
}

ConvertTo-Json -InputObject $result -Depth 8 -Compress
