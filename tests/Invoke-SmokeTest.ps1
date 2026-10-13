<#
.SYNOPSIS
    End-to-end engine test without the web server.

.DESCRIPTION
    Copies the app into a temp folder (so your real runs/ is untouched), loads
    a scenario with ArtifactFolder 'TTX-Lab-SmokeTest', runs a single step and
    then all steps, simulates a server restart, cleans up, and checks that every
    artifact the steps reported is gone. Exit code 0 = pass.

    The default scenario, 'smoke-stub' (tests/fixtures), uses stub modules that
    only write marker files, so it runs anywhere. On a Windows lab host, use
    -ScenarioId persistence-scheduled-task to test the real modules: that
    creates and removes a real, benign scheduled task named
    'TTX-Lab-SmokeTest-Updater'.
#>
[CmdletBinding()]
param(
    [string]$ScenarioId = 'smoke-stub',
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

# Does an artifact a step reported still exist on the host?
function Test-ArtifactPresent {
    param([hashtable]$Artifact)
    switch ($Artifact.type) {
        'file' {
            # Only files under ProgramData; e.g. System32\Tasks may not be readable without admin.
            if (-not $Artifact.location.StartsWith($env:ProgramData, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            return (Test-Path -LiteralPath $Artifact.location)
        }
        'scheduled-task' {
            $i = $Artifact.location.LastIndexOf('\')
            $task = Get-ScheduledTask -TaskPath $Artifact.location.Substring(0, $i + 1) -TaskName $Artifact.location.Substring($i + 1) -ErrorAction SilentlyContinue
            return ($null -ne $task)
        }
        default { return $null }   # e.g. 'process': nothing left to check
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
    $fixtures = Join-Path (Join-Path (Join-Path $repo 'tests') 'fixtures') 'scenarios'
    foreach ($dir in Get-ChildItem -LiteralPath $fixtures -Directory) {
        Copy-Item -LiteralPath $dir.FullName -Destination (Join-Path $work 'scenarios') -Recurse
    }
    Import-Engine

    $scenarios = Get-TtxScenarioList
    $sc = $scenarios | Where-Object { $_.id -eq $ScenarioId }
    Check ($null -ne $sc -and $sc.valid) "scenario '$ScenarioId' is listed and valid"

    $params = @{ ArtifactFolder = 'TTX-Lab-SmokeTest'; TaskName = 'TTX-Lab-SmokeTest-Updater' }

    $bad = $null
    try { New-TtxSession -ScenarioId $ScenarioId -Parameters @{ ArtifactFolder = '..\Windows' } | Out-Null }
    catch { $bad = $_.Exception }
    Check ($bad -is [System.ArgumentException]) "ArtifactFolder '..\Windows' is rejected"

    $view = New-TtxSession -ScenarioId $ScenarioId -Parameters $params
    $session = $view.session
    $root = $session.artifactRoot
    Write-Host "     session $($session.sessionId), artifacts in $root"
    Check ($session.steps.Count -ge 1) 'session has steps'
    Check (@($session.steps | Where-Object { $null -eq $_.info }).Count -eq 0) 'every step module was described'
    Check (@($session.steps | Where-Object { @($_.hunt).Count -eq 0 }).Count -eq 0) 'every step has hunt guidance'

    if ($ScenarioId -eq 'smoke-stub') {
        # Options: profile values fill unset options; explicit values win; bad choices fail.
        Check ($session.parameters.Flag -eq $true -and $session.parameters.Mode -eq 'a') 'loud profile defaults applied'
        Check ($session.artifactRoot -like '*TTX-Lab-SmokeTest') 'artifact folder has no session subfolder'
        $badChoice = $null
        try { New-TtxSession -ScenarioId $ScenarioId -Parameters @{ ArtifactFolder = 'TTX-Lab-SmokeTest'; Mode = 'z' } | Out-Null }
        catch { $badChoice = $_.Exception }
        Check ($badChoice -is [System.ArgumentException]) 'invalid choice value is rejected'
        $view = New-TtxSession -ScenarioId $ScenarioId -Parameters @{ ArtifactFolder = 'TTX-Lab-SmokeTest'; Profile = 'subtle'; Mode = 'a' }
        $session = $view.session
        Check ($session.parameters.Flag -eq $false) 'subtle profile sets unset option (Flag=false)'
        Check ($session.parameters.Mode -eq 'a') 'explicit option overrides the profile (Mode=a)'
        $root = $session.artifactRoot
    }

    # Dependency order: the last step can't run before the ones it depends on.
    $last = $session.steps[$session.steps.Count - 1]
    if (@($last.dependsOn).Count -gt 0) {
        $blocked = $null
        try { Start-TtxStep -StepId $last.id | Out-Null } catch { $blocked = $_.Exception }
        Check ($blocked -is [System.InvalidOperationException]) "step '$($last.id)' is blocked until its dependencies succeed"
    }

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
    $artifacts = @()
    foreach ($s in $steps) {
        Check (@($s.artifacts).Count -gt 0) "step '$($s.id)' reported artifacts (ran in PID $($s.runnerPid))"
        foreach ($a in @($s.artifacts)) {
            $artifacts += , $a
            $present = Test-ArtifactPresent $a
            if ($null -ne $present) { Check $present "$($a.type) exists: $($a.location)" }
        }
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
    foreach ($a in $artifacts) {
        $present = Test-ArtifactPresent $a
        if ($null -ne $present) { Check (-not $present) "$($a.type) removed: $($a.location)" }
    }
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
