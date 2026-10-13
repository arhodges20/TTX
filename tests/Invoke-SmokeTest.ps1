<#
.SYNOPSIS
    End-to-end engine test without the web server, against a mock Atomic Red
    Team install.

.DESCRIPTION
    Copies the app into a temp folder (so your real runs/ and scenarios/ are
    untouched) and points it at tests/fixtures/art: a mock Invoke-AtomicTest
    plus one fake technique (T9999.001) whose commands only echo text or write
    marker files in a temp folder. Nothing real is executed.

    Covers: ART preflight; catalog build and search fields (module parser and
    the powershell-yaml fallback); scenario validation, save, the
    high-impact typed confirmation and placeholders; dependency order; the
    prereq gate (refused without confirmation, then GetPrereqs); run with
    input-argument overrides and verify; the elevation block; a failing test;
    a GUID that isn't installed; cleanup after a simulated restart, in reverse
    order, with the marker gone; the answer key; and the stub module step type.

    Exit code 0 = pass. Needs the powershell-yaml module (the mock's
    Get-AtomicTechnique uses it, as the real module does).
#>
[CmdletBinding()]
param(
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ttx-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$artRoot = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'art')
$failures = 0
$savedEnv = @{ ProgramData = $env:ProgramData; TTX_SMOKE_DIR = $env:TTX_SMOKE_DIR; TTX_MOCK_ART_NO_GET = $env:TTX_MOCK_ART_NO_GET }

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

function Wait-Catalog {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (Test-TtxCatalogBuilding) {
        if ((Get-Date) -gt $deadline) { throw "Catalog still building after $TimeoutSec seconds." }
        Update-TtxEngine
        Start-Sleep -Milliseconds 200
    }
}

function Get-Step { param([string]$Id) return @((Get-TtxSessionView).session.steps | Where-Object { $_.id -eq $Id })[0] }

function Get-CaughtError {
    param([scriptblock]$Block)
    try { & $Block | Out-Null; return $null } catch { return $_.Exception }
}

function Import-Engine {
    Import-Module (Join-Path (Join-Path $work 'server') 'Engine.psm1') -Force
    Initialize-TtxEngine -Root $work -StepTimeoutSec 60 -ArtRoot $artRoot
    Wait-Catalog
}

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    foreach ($d in 'server', 'modules', 'scenarios') {
        Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $work -Recurse
    }
    $fixtures = Join-Path (Join-Path (Join-Path $repo 'tests') 'fixtures') 'scenarios'
    Copy-Item -Path (Join-Path $fixtures '*.json') -Destination (Join-Path $work 'scenarios')
    New-Item -ItemType Directory -Path (Join-Path $work 'runs') | Out-Null
    # Stub steps write under %ProgramData%; ART fixture markers go here.
    $env:ProgramData = Join-Path $work 'programdata'
    New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
    $env:TTX_SMOKE_DIR = Join-Path $work 'markers'
    $marker = Join-Path $env:TTX_SMOKE_DIR 'smoke-marker.txt'

    # ---- ART preflight ----
    Import-Module (Join-Path (Join-Path $work 'server') 'Engine.psm1') -Force
    $pf = Get-TtxPreflight -ArtRoot $artRoot
    Check ($pf.art.moduleImportable -and $pf.art.moduleVersion) "preflight: ART module importable (version $($pf.art.moduleVersion))"
    Check ($pf.art.atomicsFound -and $pf.art.techniqueCount -eq 1) 'preflight: atomics folder found (1 technique)'
    Check ($pf.art.yamlAvailable) 'preflight: powershell-yaml available'
    Check ($null -ne $pf.falconService) "preflight: Falcon check still runs (sensor: $($pf.falconService))"
    $pfMissing = Get-TtxPreflight -ArtRoot (Join-Path $work 'no-art-here')
    Check (-not $pfMissing.art.rootFound -and @($pfMissing.warnings | Where-Object { $_ -like '*Atomic Red Team was not found*' }).Count -eq 1) 'preflight: missing ART is a clear warning'

    # ---- Catalog ----
    Import-Engine
    $cs = Get-TtxCatalogStatus
    Check ($cs.status -eq 'ready' -and $cs.parser -eq 'Get-AtomicTechnique') "catalog built with the module's Get-AtomicTechnique ($($cs.count) tests)"
    $cat = ConvertFrom-TtxJson -Json (Get-TtxCatalogJson)
    $guids = @($cat.tests | ForEach-Object { $_.guid })
    Check ($cat.tests.Count -eq 4) 'catalog: 4 Windows tests (the Linux-only test is filtered out)'
    Check ($guids -notcontains '44444444-4444-4444-8444-444444444444') 'catalog: Linux-only test absent'
    $t1 = Get-TtxCatalogTest -Guid '11111111-1111-4111-8111-111111111111'
    Check ($t1.techniqueId -eq 'T9999.001' -and $t1.techniqueName -eq 'TTX Fixture Technique' -and $t1.testName -eq 'Write marker file') 'catalog: technique id/name and test name'
    Check ($t1.executor -eq 'powershell' -and $t1.elevationRequired -eq $false -and $t1.platforms -contains 'windows') 'catalog: executor, elevation_required, platforms'
    Check (@($t1.inputArguments | Where-Object { $_.name -eq 'marker_name' -and $_.default -eq 'marker.txt' }).Count -eq 1) 'catalog: input arguments with defaults'
    Check ($t1.hasDependencies -and $t1.prereqDownloads -and $t1.description -like 'Fixture test*') 'catalog: description, dependencies, prereq download flag'
    Check ((Get-TtxCatalogTest -Guid '33333333-3333-4333-8333-333333333333').elevationRequired) 'catalog: elevation flag on the elevated fixture test'
    $prev = Get-TtxAtomicPreview -Guid $t1.guid -InputArguments @{ marker_name = 'x.txt'; bogus = '1' }
    Check ($prev.command -like '*"x.txt"*' -and $prev.command -notlike '*#{*') 'preview: input arguments substituted into the command'
    Check (Test-Path -LiteralPath (Join-Path (Join-Path $work 'runs') 'catalog.json')) 'catalog cached in runs/catalog.json'

    $env:TTX_MOCK_ART_NO_GET = '1'
    Start-TtxCatalogBuild
    Wait-Catalog
    $cs2 = Get-TtxCatalogStatus
    Check ($cs2.status -eq 'ready' -and $cs2.parser -eq 'powershell-yaml' -and $cs2.count -eq 4) 'catalog: powershell-yaml fallback when Get-AtomicTechnique is not exported'
    $env:TTX_MOCK_ART_NO_GET = $savedEnv.TTX_MOCK_ART_NO_GET

    # ---- Scenarios: listing, validation, builder save, guardrails ----
    $list = Get-TtxScenarioList
    $ex = @($list | Where-Object { $_.id -eq 'persistence-schtask' })[0]
    Check ($null -ne $ex -and $ex.valid -and -not $ex.loadable) 'example scenario is valid but not loadable until GUIDs are chosen'
    Check (@($ex.incomplete | Where-Object { $_ -like '*atomic_guid*' }).Count -eq 2 -and @($ex.incomplete | Where-Object { $_ -like '*placeholder*' }).Count -eq 1) 'example scenario reports missing GUIDs and the verify placeholder'
    Check ((Get-CaughtError { New-TtxSession -ScenarioId 'persistence-schtask' }) -is [System.ArgumentException]) 'loading the example before choosing tests is refused'
    $smoke = @($list | Where-Object { $_.id -eq 'smoke-art' })[0]
    Check ($smoke.loadable) 'smoke-art scenario is loadable'
    $guards = @($list | Where-Object { $_.id -eq 'smoke-art-guards' })[0]
    Check ($guards.loadable -and @($guards.warnings | Where-Object { $_ -like '*99999999*not found*' }).Count -eq 1) 'a GUID missing from the installed atomics is a warning'

    $draft = @{
        id = 'builder-draft'; name = 'Builder draft'
        steps = @(
            @{ id = 'a'; title = 'A'; technique = 'T9999.001'; atomic_guid = '22222222-2222-4222-8222-222222222222'; input_arguments = @{ message = 'hi' }; expected_detections = @('X'); hunt_notes = @('Y'); verify = @() },
            @{ id = 'b'; title = 'B'; technique = 'T1490'; atomic_guid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; depends_on = @('a') }
        )
    }
    $e = Get-CaughtError { Save-TtxScenario -Scenario $draft -Overwrite $false }
    Check ($e -is [System.ArgumentException] -and $e.Message -like '*T1490*high-impact*') 'save refused: high-impact technique without typed confirmation'
    $draft.steps[1].high_impact_confirmation = 'T1490'
    $saved = Save-TtxScenario -Scenario $draft -Overwrite $false
    Check ($saved.saved -and (Test-Path -LiteralPath (Join-Path (Join-Path $work 'scenarios') 'builder-draft.json'))) 'save accepted with the typed confirmation; written to scenarios/builder-draft.json'
    Check ((Get-CaughtError { Save-TtxScenario -Scenario $draft -Overwrite $false }) -is [System.InvalidOperationException]) 'save refuses to overwrite without overwrite flag'
    $reloaded = Get-TtxScenario -Id 'builder-draft'
    Check ($reloaded.scenario.steps[0].input_arguments.message -eq 'hi' -and $reloaded.scenario.steps[1].depends_on[0] -eq 'a') 'saved scenario round-trips (overrides, dependencies)'
    $badDep = @{ id = 'bad-dep'; name = 'Bad'; steps = @(@{ id = 'a'; title = 'A'; technique = 'T9999.001'; atomic_guid = '22222222-2222-4222-8222-222222222222'; depends_on = @('later') }, @{ id = 'later'; title = 'L'; technique = 'T9999.001'; atomic_guid = '22222222-2222-4222-8222-222222222222' }) }
    Check ((Get-CaughtError { Save-TtxScenario -Scenario $badDep -Overwrite $false }) -is [System.ArgumentException]) 'save refused: dependency on a later step'
    $badVerify = @{ id = 'bad-verify'; name = 'Bad'; steps = @(@{ id = 'a'; title = 'A'; technique = 'T9999.001'; atomic_guid = '22222222-2222-4222-8222-222222222222'; verify = @(@{ type = 'rm_rf'; path = 'x' }) }) }
    Check ((Get-CaughtError { Save-TtxScenario -Scenario $badVerify -Overwrite $false }) -is [System.ArgumentException]) 'save refused: unknown verify type'

    # ---- ART session: dependency order, prereq gate, run, verify ----
    $view = New-TtxSession -ScenarioId 'smoke-art'
    $session = $view.session
    Write-Host "     session $($session.sessionId)"
    Check ($session.art.root -eq $artRoot -and $session.preflight.art.moduleImportable) 'session records the ART root and preflight'
    $m1 = Get-Step 'marker-1'
    Check ($m1.atomic.command -like "*smoke-marker.txt*" -and $m1.values.marker_dir -eq '$env:TTX_SMOKE_DIR') 'session snapshot: command after substitution'

    $e = Get-CaughtError { Start-TtxStep -StepId 'marker-1' }
    Check ($e -is [System.InvalidOperationException] -and $e.Message -like '*requires*') 'dependency order: marker-1 refused before echo-1 succeeds'

    Start-TtxStep -StepId 'echo-1' | Out-Null
    Wait-Idle
    $s1 = Get-Step 'echo-1'
    Check ($s1.status -eq 'succeeded' -and $s1.executed) 'echo-1 succeeded'
    Check ($s1.run.exitCode -eq 0 -and $s1.run.exitCodeSource -eq 'execution log') 'echo-1 exit code 0 read from the execution log'
    Check ($s1.run.output -like '*TTX fixture echo: smoke override*') 'echo-1 output captured with the input-argument override'
    Check ($s1.run.startUtc -and $s1.run.endUtc -and $s1.run.command -like '*smoke override*') 'echo-1 UTC window and command recorded'
    Check (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $work 'runs') $session.sessionId) 'art-execution-log.csv')) 'per-run execution log under runs/<id>/'

    $e = Get-CaughtError { New-TtxSession -ScenarioId 'smoke-art' }
    Check ($e -is [System.InvalidOperationException]) 'loading another scenario is blocked until cleanup'

    Start-TtxStep -StepId 'marker-1' | Out-Null
    Wait-Idle
    $m1 = Get-Step 'marker-1'
    Check ($m1.status -eq 'prereqs-missing' -and -not $m1.executed) 'marker-1 stopped at the prereq check (nothing executed)'
    Check (@($m1.prereqs.missing).Count -eq 1 -and $m1.prereqs.missing[0] -like 'Fixture prereq file*') 'missing prereq reported'
    Check (-not (Test-Path -LiteralPath $marker)) 'no marker written before prereqs are met'
    Check (@($m1.atomic.dependencies | Where-Object { $_.getPrereqCommand -like '*prereq.txt*' -and $_.getPrereqCommand -notlike '*#{*' }).Count -eq 1) 'what GetPrereqs would run is available (substituted)'

    Check ((Get-CaughtError { Start-TtxGetPrereqs -StepId 'marker-1' -Confirm $false -ConfirmDownload $true }) -is [System.ArgumentException]) 'GetPrereqs refused without confirmation'
    Check ((Get-CaughtError { Start-TtxGetPrereqs -StepId 'marker-1' -Confirm $true -ConfirmDownload $false }) -like '*download*') 'GetPrereqs refused without the download acknowledgement'
    Start-TtxGetPrereqs -StepId 'marker-1' -Confirm $true -ConfirmDownload $true | Out-Null
    Wait-Idle
    $m1 = Get-Step 'marker-1'
    Check ($m1.status -eq 'pending' -and $m1.prereqs.status -eq 'met' -and $m1.prereqsFetched) 'GetPrereqs satisfied the prereq'

    Start-TtxStep -StepId 'marker-1' | Out-Null
    Wait-Idle
    $m1 = Get-Step 'marker-1'
    Check ($m1.status -eq 'succeeded') 'marker-1 succeeded'
    Check ((Test-Path -LiteralPath $marker)) "marker written by the atomic: $marker"
    $vr = @($m1.verifyResults)
    $target = if ($vr.Count -gt 0) { [System.IO.Path]::GetFullPath([string]$vr[0].target) } else { '' }
    Check ($vr.Count -eq 1 -and $vr[0].result -eq 'pass' -and $target -eq [System.IO.Path]::GetFullPath($marker)) 'verify file_exists passed (input args and $env: expanded)'

    Set-TtxDetectionResult -StepId 'marker-1' -DetectionId 'exp-1' -Result 'fired' -Notes 'seen in console' | Out-Null
    Set-TtxDetectionResult -StepId 'marker-1' -DetectionId 'custom:Unexpected one' -Result 'fired' | Out-Null
    $rows = (Get-TtxSessionView).stepExtras['marker-1'].detections
    Check (@($rows).Count -eq 3 -and @($rows | Where-Object { $_.id -eq 'exp-1' -and $_.result -eq 'fired' }).Count -eq 1) 'detection checklist: expected rows plus a custom row, results saved'
    Check ((Get-TtxSessionView).stepExtras['echo-1'].huntNotes[0] -like '*message smoke override*') 'hunt notes expand {{placeholders}}'
    Check ($null -ne (Get-TtxSessionView).readyToHunt.readyAtUtc) 'ready-to-hunt estimate available'

    # ---- Restart, then cleanup driven from saved state ----
    $sid = $session.sessionId
    Remove-Module Engine -Force
    Import-Engine
    $restored = (Get-TtxSessionView).session
    Check ($null -ne $restored -and $restored.sessionId -eq $sid) 'session restored after restart'
    Start-TtxCleanup | Out-Null
    Wait-Idle
    $after = (Get-TtxSessionView)
    Check ($after.session.status -eq 'cleaned') 'cleanup after restart: session closed'
    Check (@($after.session.steps | Where-Object { $_.cleanup.status -ne 'succeeded' }).Count -eq 0) 'every executed step cleaned up (marked in state)'
    Check (-not (Test-Path -LiteralPath $marker)) 'marker removed by ART cleanup'
    $order = @($after.events | Where-Object { $_.message -like 'Cleaning up:*' } | ForEach-Object { $_.stepId })
    Check (($order -join ',') -eq 'marker-1,echo-1') "cleanup ran in reverse order ($($order -join ' -> '))"

    $keyPath = Join-Path (Join-Path (Join-Path $work 'runs') $sid) 'answer-key.md'
    $key = if (Test-Path -LiteralPath $keyPath) { Get-Content -LiteralPath $keyPath -Raw } else { '' }
    Check ($key -like '*Host*' -and $key -like '*Falcon AID*' -and $key -like '*Smoke test (mock ART)*') 'answer key: host, AID, scenario'
    Check ($key -like '*T9999.001*Write marker file*' -and $key -like '*11111111-1111-4111-8111-111111111111*') 'answer key: technique, test name, GUID'
    Check ($key -like '*Command that ran*smoke-marker.txt*' -and $key -like '*UTC window*') 'answer key: command that ran and UTC window'
    Check ($key -like '*file_exists*pass*' -and $key -like '*Marker file smoke-marker.txt*') 'answer key: verify results and hunt notes'
    Check ($key -like '*Fixture detection B*fired*seen in console*' -and $key -like '*Unexpected one*') 'answer key: detection checklist results'
    Check ($key -like '*Telemetry may take a few minutes*' -and $key -like '*Ready to hunt*') 'answer key: telemetry note and ready-to-hunt estimate'

    # ---- Guardrails: elevation, failing test, missing GUID ----
    $view = New-TtxSession -ScenarioId 'smoke-art-guards'
    $e = Get-CaughtError { Start-TtxStep -StepId 'missing-1' }
    Check ($e -is [System.InvalidOperationException] -and $e.Message -like '*not found in the installed atomics*') 'step with an uninstalled GUID refused'
    if ($view.session.preflight.elevated) {
        # Elevated console: the elevated fixture test is allowed and runs (it only echoes).
        Write-Host '     (running elevated: checking the elevated test runs instead of being blocked)'
        Start-TtxStep -StepId 'elev-1' | Out-Null
        Wait-Idle
        Check ((Get-Step 'elev-1').status -eq 'succeeded') 'elevated test runs when the control center is elevated'
    }
    else {
        $e = Get-CaughtError { Start-TtxStep -StepId 'elev-1' }
        Check ($e -is [System.InvalidOperationException] -and $e.Message -like '*requires elevation*') 'elevated test blocked when the control center is not elevated'
        Check ((Get-CaughtError { Start-TtxRunAll }) -like '*Run all refused*') 'run all refused up front when a step is blocked'
    }
    Start-TtxStep -StepId 'fail-1' | Out-Null
    Wait-Idle
    $f1 = Get-Step 'fail-1'
    Check ($f1.status -eq 'failed' -and $f1.run.exitCode -eq 3 -and $f1.executed) 'non-zero exit code marks the step failed (still cleaned up later)'
    Start-TtxCleanup | Out-Null
    Wait-Idle
    $g = (Get-TtxSessionView).session
    Check ($g.status -eq 'cleaned' -and (Get-Step 'missing-1').cleanup.status -eq 'skipped') 'cleanup skips steps that never ran'

    # ---- Stub module steps (engine test step type) ----
    $e = Get-CaughtError { New-TtxSession -ScenarioId 'smoke-stub' -Parameters @{ ArtifactFolder = '..\Windows' } }
    Check ($e -is [System.ArgumentException]) "ArtifactFolder '..\Windows' is rejected"
    $view = New-TtxSession -ScenarioId 'smoke-stub' -Parameters @{ ArtifactFolder = 'TTX-Lab-SmokeTest'; Intensity = 'high' }
    Check ($view.session.parameters.Label -eq 'noisy' -and $view.session.parameters.Flag -eq $true) 'profile values fill unset options'
    $view = New-TtxSession -ScenarioId 'smoke-stub' -Parameters @{ ArtifactFolder = 'TTX-Lab-SmokeTest'; Intensity = 'high'; Label = 'mine' }
    Check ($view.session.parameters.Label -eq 'mine') 'explicit option overrides the profile'
    Start-TtxRunAll | Out-Null
    Wait-Idle
    $st = (Get-TtxSessionView).session
    Check (@($st.steps | Where-Object { $_.status -ne 'succeeded' }).Count -eq 0) 'stub run all: every step succeeded'
    Check (@($st.steps | Where-Object { @($_.artifacts).Count -eq 0 }).Count -eq 0) 'stub steps reported their marker files'
    Start-TtxCleanup | Out-Null
    Wait-Idle
    $st = (Get-TtxSessionView).session
    Check ($st.status -eq 'cleaned') 'stub cleanup closed the session'
    Check (-not (Test-Path -LiteralPath (Join-Path $env:ProgramData 'TTX-Lab-SmokeTest'))) 'stub artifact folder removed'
}
catch {
    $failures++
    Write-Host "FAIL $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
}
finally {
    if (Get-Module Engine) {
        try { Stop-TtxEngine } catch { Write-Verbose $_.Exception.Message }
        Get-Module Engine | Remove-Module -Force
    }
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

if ($failures -gt 0) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'Smoke test passed.' -ForegroundColor Green
exit 0
