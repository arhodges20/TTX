<#
.SYNOPSIS
    End-to-end engine test without the web server.

.DESCRIPTION
    Copies the app into a temp folder (so your real runs/ is untouched), loads
    the scheduled-task scenario with ArtifactFolder 'TTX-Lab-SmokeTest', runs
    all steps, simulates a server restart, cleans up, and checks that every
    marker and folder is gone. Exit code 0 = pass.
#>
[CmdletBinding()]
param(
    [string]$ScenarioId = 'persistence-scheduled-task',
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ttx-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$failures = 0

function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "ok   $Message" }
    else { $script:failures++; Write-Host "FAIL $Message" -ForegroundColor Red }
}

function Wait-Idle {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-TtxSessionView).busy) {
        if ((Get-Date) -gt $deadline) { throw "Engine still busy after $TimeoutSec seconds." }
        Update-TtxEngine
        Start-Sleep -Milliseconds 200
    }
}

function Import-Engine {
    Import-Module (Join-Path (Join-Path $work 'server') 'Engine.psm1') -Force
    Initialize-TtxEngine -Root $work -StepTimeoutSec 60
}

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    foreach ($d in 'server', 'modules', 'scenarios') {
        Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $work -Recurse
    }
    Import-Engine

    $scenarios = Get-TtxScenarioList
    $sc = $scenarios | Where-Object { $_.id -eq $ScenarioId }
    Check ($null -ne $sc -and $sc.valid) "scenario '$ScenarioId' is listed and valid"

    $bad = $null
    try { New-TtxSession -ScenarioId $ScenarioId -Parameters @{ ArtifactFolder = '..\Windows' } | Out-Null }
    catch { $bad = $_.Exception }
    Check ($bad -is [System.ArgumentException]) "ArtifactFolder '..\Windows' is rejected"

    $view = New-TtxSession -ScenarioId $ScenarioId -Parameters @{ ArtifactFolder = 'TTX-Lab-SmokeTest' }
    $session = $view.session
    $root = $session.artifactRoot
    Write-Host "     session $($session.sessionId), artifacts in $root"
    Check ($session.steps.Count -ge 1) 'session has steps'
    Check (@($session.steps | Where-Object { $null -eq $_.info }).Count -eq 0) 'every step module was described'
    Check (@($session.steps | Where-Object { @($_.hunt).Count -eq 0 }).Count -eq 0) 'every step has hunt guidance'

    $first = $session.steps[0].id
    Start-TtxStep -StepId $first | Out-Null
    Wait-Idle
    Check ((Get-TtxSessionView).session.steps[0].status -eq 'succeeded') "single step '$first' succeeded"

    $conflict = $null
    try { New-TtxSession -ScenarioId $ScenarioId | Out-Null } catch { $conflict = $_.Exception }
    Check ($conflict -is [System.InvalidOperationException]) 'loading a new scenario is blocked until cleanup'

    Start-TtxRunAll | Out-Null
    Wait-Idle
    $steps = (Get-TtxSessionView).session.steps
    Check (@($steps | Where-Object { $_.status -ne 'succeeded' }).Count -eq 0) 'run all: every step succeeded'
    foreach ($s in $steps) {
        Check (Test-Path -LiteralPath (Join-Path $root "$($s.id).marker")) "marker for '$($s.id)' exists"
    }

    # Simulate a restart: reload the module and engine from disk.
    Remove-Module Engine -Force
    Import-Engine
    $restored = (Get-TtxSessionView).session
    Check ($null -ne $restored -and $restored.sessionId -eq $session.sessionId) 'session restored after restart'

    Start-TtxCleanup | Out-Null
    Wait-Idle
    $after = (Get-TtxSessionView)
    Check ($after.session.status -eq 'cleaned') 'session status is cleaned'
    Check (@($after.session.steps | Where-Object { $_.status -ne 'cleaned' }).Count -eq 0) 'every step cleaned'
    Check (-not (Test-Path -LiteralPath $root)) 'session artifact folder removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $env:ProgramData 'TTX-Lab-SmokeTest'))) 'empty ArtifactFolder removed'
    Check ($after.eventCount -gt 0) "event log has $($after.eventCount) events"
}
catch {
    $failures++
    Write-Host "FAIL $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
}
finally {
    Get-Module Engine | Remove-Module -Force
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

if ($failures -gt 0) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'Smoke test passed.' -ForegroundColor Green
exit 0
