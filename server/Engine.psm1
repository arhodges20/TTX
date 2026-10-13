# TTX Control Center engine: ART catalog, scenarios, sessions, step
# execution, saved state, detection checklist and answer key.
# Windows PowerShell 5.1.
#
# All engine state is touched only from the server's single thread. Steps and
# the catalog build run in background jobs; Update-TtxEngine (called from the
# server loop) collects finished jobs and starts the next queued operation.
# The engine is the only writer of runs/<sessionId>/state.json and
# events.jsonl.
#
# Attack steps are Atomic Red Team tests (decision D19): the engine only
# orchestrates Invoke-AtomicTest through server/ArtRunner.ps1. Stub module
# steps (modules/stub-*) remain for engine tests.

. (Join-Path $PSScriptRoot 'TtxCommon.ps1')
. (Join-Path $PSScriptRoot 'Art.ps1')
. (Join-Path $PSScriptRoot 'Verify.ps1')
. (Join-Path $PSScriptRoot 'Preflight.ps1')

$script:Ttx = @{
    Root               = $null
    RunsDir            = $null
    ScenariosDir       = $null
    ModulesDir         = $null
    RunnerPath         = $null
    ArtRunnerPath      = $null
    CatalogBuilderPath = $null
    CatalogPath        = $null
    ArtRoot            = $null
    StepTimeoutSec     = 120
    TelemetryDelayMin  = 5
    Session            = $null                                  # hashtable saved to state.json
    Revision           = 0                                      # bumps on every session change
    Events             = New-Object System.Collections.ArrayList  # current session's events
    Queue              = New-Object System.Collections.ArrayList  # @{ stepId; op } waiting to run
    Job                = $null                                  # running step job
    JobItem            = $null                                  # @{ stepId; op } for that job
    JobStarted         = $null
    JobTimeoutSec      = 120
    Catalog            = $null                                  # see Reset-TtxCatalog
    CatalogJob         = $null
    CatalogJobStarted  = $null
}

$script:IdPattern = '^[A-Za-z0-9][A-Za-z0-9_-]*$'
$script:FolderPattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]*([\\/][A-Za-z0-9][A-Za-z0-9 ._-]*)*$'
$script:TechniquePattern = '^T\d{4}(\.\d{3})?$'
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:CatalogJobTimeoutSec = 900

#region Errors (mapped to HTTP status codes by the server)

function New-TtxBadRequest { param([string]$Message) New-Object System.ArgumentException $Message }
function New-TtxConflict { param([string]$Message) New-Object System.InvalidOperationException $Message }
function New-TtxNotFound { param([string]$Message) New-Object System.Collections.Generic.KeyNotFoundException $Message }

#endregion

#region Events and saved state

function Get-TtxUtcNow { return (Get-Date).ToUniversalTime().ToString('o') }

function Add-TtxEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info',
        [string]$StepId,
        [string]$Timestamp
    )
    if ([string]::IsNullOrEmpty($Timestamp)) { $Timestamp = (Get-Date).ToString('o') }
    $evt = @{
        seq     = $script:Ttx.Events.Count
        ts      = $Timestamp
        level   = $Level
        stepId  = $StepId
        message = $Message
    }
    [void]$script:Ttx.Events.Add($evt)
    if ($script:Ttx.Session) {
        $path = Join-Path (Get-TtxSessionDir) 'events.jsonl'
        $line = (ConvertTo-TtxJson -InputObject $evt -Compress) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding $false))
    }
    $prefix = if ($StepId) { "[$StepId] " } else { '' }
    Write-Verbose "$Level $prefix$Message"
}

function Get-TtxSessionDir {
    return (Join-Path $script:Ttx.RunsDir $script:Ttx.Session.sessionId)
}

function Save-TtxSession {
    $s = $script:Ttx.Session
    if (-not $s) { return }
    $s.updatedAt = (Get-Date).ToString('o')
    $script:Ttx.Revision++
    Write-TtxTextFile -Path (Join-Path (Get-TtxSessionDir) 'state.json') -Text (ConvertTo-TtxJson -InputObject $s)
}

function Get-TtxStep {
    param([Parameter(Mandatory = $true)][string]$StepId)
    foreach ($step in $script:Ttx.Session.steps) {
        if ($step.id -eq $StepId) { return $step }
    }
    return $null
}

function Test-TtxBusy {
    return ($null -ne $script:Ttx.Job -or $script:Ttx.Queue.Count -gt 0)
}

# True if any step ran (or may have run) on the host and so needs cleanup.
function Test-TtxSessionTouched {
    foreach ($step in $script:Ttx.Session.steps) {
        if ($step.executed) { return $true }
    }
    return $false
}

#endregion

#region ART catalog

function Reset-TtxCatalog {
    $script:Ttx.Catalog = @{
        status      = 'none'     # none | building | ready | error
        error       = $null
        meta        = $null      # catalog.json fields other than tests
        byGuid      = @{}
        summaryJson = '[]'
        stale       = $false
    }
}

function Get-TtxCatalogSummaryRow {
    param([hashtable]$Test)
    return @{
        guid              = $Test.guid
        techniqueId       = $Test.techniqueId
        techniqueName     = $Test.techniqueName
        testNumber        = $Test.testNumber
        testName          = $Test.testName
        executor          = $Test.executor
        elevationRequired = $Test.elevationRequired
        hasDependencies   = $Test.hasDependencies
        prereqDownloads   = $Test.prereqDownloads
        commandDownloads  = $Test.commandDownloads
        highImpact        = $Test.highImpact
        inputCount        = @($Test.inputArguments).Count
    }
}

# Loads runs/catalog.json if it describes the configured ART install.
function Import-TtxCatalogCache {
    $path = $script:Ttx.CatalogPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $cat = ConvertFrom-TtxJson -Json (Read-TtxTextFile -Path $path)
    }
    catch {
        Write-Warning "Ignoring unreadable catalog cache $path : $($_.Exception.Message)"
        return $false
    }
    $paths = Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot
    if ($cat -isnot [hashtable] -or [string]$cat.atomicsPath -ne [string]$paths.atomicsPath) { return $false }

    $byGuid = @{}
    $rows = New-Object System.Collections.ArrayList
    foreach ($t in @($cat.tests)) {
        if ($null -eq $t) { continue }
        $byGuid[([string]$t.guid).ToLowerInvariant()] = $t
        [void]$rows.Add((Get-TtxCatalogSummaryRow -Test $t))
    }
    $meta = @{}
    foreach ($k in @($cat.Keys)) { if ($k -ne 'tests') { $meta[$k] = $cat[$k] } }
    $meta.count = $rows.Count
    $script:Ttx.Catalog.meta = $meta
    $script:Ttx.Catalog.byGuid = $byGuid
    $script:Ttx.Catalog.summaryJson = ConvertTo-TtxJson -InputObject @($rows) -Compress
    if ($rows.Count -eq 0) { $script:Ttx.Catalog.summaryJson = '[]' }
    $script:Ttx.Catalog.status = 'ready'
    $script:Ttx.Catalog.error = $null
    return $true
}

# Starts a background catalog build (no-op if one is already running).
function Start-TtxCatalogBuild {
    if ($script:Ttx.CatalogJob) { return }
    $paths = Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot
    if (-not (Test-Path -LiteralPath $paths.atomicsPath -PathType Container)) {
        $script:Ttx.Catalog.status = 'error'
        $script:Ttx.Catalog.error = "Atomics folder not found at $($paths.atomicsPath). Install Atomic Red Team or set the ART root."
        return
    }
    $script:Ttx.CatalogJob = Start-Job -ArgumentList $script:Ttx.CatalogBuilderPath, $script:Ttx.ArtRoot, $script:Ttx.CatalogPath -ScriptBlock {
        param($BuilderPath, $ArtRoot, $OutPath)
        & $BuilderPath -ArtRoot $ArtRoot -OutPath $OutPath
    }
    $script:Ttx.CatalogJobStarted = Get-Date
    $script:Ttx.Catalog.status = 'building'
    $script:Ttx.Catalog.error = $null
}

function Update-TtxCatalogJob {
    $job = $script:Ttx.CatalogJob
    if (-not $job) { return }
    $timedOut = ((Get-Date) - $script:Ttx.CatalogJobStarted).TotalSeconds -gt $script:CatalogJobTimeoutSec
    if ($job.State -notin 'Completed', 'Failed', 'Stopped' -and -not $timedOut) { return }
    if ($timedOut) { Stop-Job -Job $job }
    $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
    Remove-Job -Job $job -Force
    $script:Ttx.CatalogJob = $null
    $summary = $null
    $json = $out | Where-Object { $_ -is [string] -and $_.StartsWith('{') } | Select-Object -Last 1
    if ($json) { try { $summary = ConvertFrom-TtxJson -Json $json } catch { $summary = $null } }

    if ($summary -and $summary.ok -and (Import-TtxCatalogCache)) {
        $script:Ttx.Catalog.stale = $false
        return
    }
    $msg = if ($timedOut) { "Catalog build timed out after $($script:CatalogJobTimeoutSec) seconds." }
    elseif ($summary -and $summary.error) { [string]$summary.error }
    elseif ($jobErrors) { ($jobErrors | ForEach-Object { $_.ToString() }) -join '; ' }
    else { 'Catalog build produced no result.' }
    # Keep serving an older catalog if there is one.
    if ($script:Ttx.Catalog.meta) { $script:Ttx.Catalog.status = 'ready' } else { $script:Ttx.Catalog.status = 'error' }
    $script:Ttx.Catalog.error = $msg
}

function Initialize-TtxCatalog {
    Reset-TtxCatalog
    $loaded = Import-TtxCatalogCache
    $paths = Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot
    $fingerprint = Get-TtxAtomicsFingerprint -AtomicsPath $paths.atomicsPath
    if ($null -eq $fingerprint) {
        if (-not $loaded) {
            $script:Ttx.Catalog.status = 'error'
            $script:Ttx.Catalog.error = "Atomics folder not found at $($paths.atomicsPath)."
        }
        return
    }
    if (-not $loaded -or [string]$script:Ttx.Catalog.meta.fingerprint -ne $fingerprint) {
        $script:Ttx.Catalog.stale = $loaded
        Start-TtxCatalogBuild
    }
}

function Get-TtxCatalogStatus {
    $c = $script:Ttx.Catalog
    $m = $c.meta
    return @{
        status         = $c.status
        error          = $c.error
        stale          = $c.stale
        building       = ($null -ne $script:Ttx.CatalogJob)
        artRoot        = $script:Ttx.ArtRoot
        atomicsPath    = (Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot).atomicsPath
        builtAtUtc     = if ($m) { $m.builtAtUtc } else { $null }
        parser         = if ($m) { $m.parser } else { $null }
        artVersion     = if ($m) { $m.artVersion } else { $null }
        count          = if ($m) { $m.count } else { 0 }
        techniqueCount = if ($m) { $m.techniqueCount } else { 0 }
        parseErrors    = if ($m) { @(@($m.errors) | Select-Object -First 20) } else { @() }
    }
}

# The catalog list for the UI as a JSON string (built once per load; the full
# list can hold over a thousand tests).
function Get-TtxCatalogJson {
    $status = ConvertTo-TtxJson -InputObject (Get-TtxCatalogStatus) -Compress
    return '{"status":' + $status + ',"tests":' + $script:Ttx.Catalog.summaryJson + '}'
}

function Get-TtxCatalogTest {
    param([string]$Guid)
    if ([string]::IsNullOrWhiteSpace($Guid)) { return $null }
    return $script:Ttx.Catalog.byGuid[$Guid.Trim().ToLowerInvariant()]
}

# What a test would run with the given overrides: the command, cleanup
# command and prereq commands after input-argument substitution.
function Get-TtxAtomicPreview {
    param([string]$Guid, [hashtable]$InputArguments)
    $t = Get-TtxCatalogTest -Guid $Guid
    if (-not $t) { throw (New-TtxNotFound "Test $Guid is not in the installed atomics catalog.") }
    $atomics = (Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot).atomicsPath
    $values = Get-TtxResolvedInputArgs -Definitions $t.inputArguments -Overrides $InputArguments
    return @{
        test           = $t
        values         = $values
        command        = Expand-TtxAtomicCommand $t.command $values $atomics
        cleanupCommand = Expand-TtxAtomicCommand $t.cleanupCommand $values $atomics
        dependencies   = @(foreach ($d in @($t.dependencies)) {
                if ($null -eq $d) { continue }
                @{
                    description      = Expand-TtxAtomicCommand $d.description $values $atomics
                    prereqCommand    = Expand-TtxAtomicCommand $d.prereqCommand $values $atomics
                    getPrereqCommand = Expand-TtxAtomicCommand $d.getPrereqCommand $values $atomics
                    downloads        = [bool]$d.downloads
                }
            })
    }
}

#endregion

#region Scenarios

function Get-TtxModulePath {
    param([string]$ModuleId)
    return (Join-Path (Join-Path $script:Ttx.ModulesDir $ModuleId) 'module.ps1')
}

function Get-TtxScenarioPath {
    param([string]$Id)
    return (Join-Path $script:Ttx.ScenariosDir "$Id.json")
}

function Test-TtxHasModuleSteps {
    param([hashtable]$Scenario)
    return (@(@($Scenario.steps) | Where-Object { $_ -is [hashtable] -and $_.module }).Count -gt 0)
}

# Returns the scenario's parameter list. ArtifactFolder is added for
# scenarios with stub module steps (the only steps that write to it).
# Each parameter: name, default, description, type (string|choice|bool), choices.
function Get-TtxScenarioParameters {
    param([hashtable]$Scenario)
    $list = @()
    $hasFolder = $false
    foreach ($p in @($Scenario.parameters)) {
        if ($null -eq $p) { continue }
        if ($p.name -eq 'ArtifactFolder') { $hasFolder = $true }
        $type = [string]$p.type
        if ($type -notin 'string', 'choice', 'bool') { $type = 'string' }
        $list += , @{
            name        = [string]$p.name
            default     = $p.default
            description = [string]$p.description
            type        = $type
            choices     = @($p.choices | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }
    }
    if (-not $hasFolder -and (Test-TtxHasModuleSteps $Scenario)) {
        $list += , @{ name = 'ArtifactFolder'; default = 'TTX-Lab'; description = 'Folder under %ProgramData% where stub steps write marker files.'; type = 'string'; choices = @() }
    }
    return , $list
}

# Profiles: an optional scenario-level map, e.g.
#   "profileParameter": "Intensity",
#   "profiles": { "quick": { "SomeOption": "a" }, "full": { ... } }
# Options the admin sets explicitly win; unset ones take the profile's value.
function Get-TtxScenarioProfiles {
    param([hashtable]$Scenario)
    if ($Scenario.profiles -is [hashtable]) { return $Scenario.profiles }
    return @{}
}

function ConvertTo-TtxParameterValue {
    param([hashtable]$Definition, $Value)
    switch ($Definition.type) {
        'bool' {
            if ($Value -is [bool]) { return $Value }
            $text = ([string]$Value).Trim().ToLowerInvariant()
            if ($text -in 'true', '1', 'yes', 'on') { return $true }
            if ($text -in 'false', '0', 'no', 'off') { return $false }
            throw (New-TtxBadRequest "$($Definition.name) must be true or false (got '$Value').")
        }
        'choice' {
            $text = ([string]$Value).Trim()
            $match = @($Definition.choices | Where-Object { $_ -eq $text })
            if ($match.Count -eq 0) {
                throw (New-TtxBadRequest "$($Definition.name) must be one of: $($Definition.choices -join ', ') (got '$text').")
            }
            return [string]$match[0]
        }
        default { return ([string]$Value).Trim() }
    }
}

# Resolves the session's parameter values: explicit value > profile value > default.
function Resolve-TtxParameters {
    param([hashtable]$Scenario, [hashtable]$Given)
    if ($null -eq $Given) { $Given = @{} }
    $defs = Get-TtxScenarioParameters -Scenario $Scenario
    $isGiven = {
        param($name)
        $Given.ContainsKey($name) -and $null -ne $Given[$name] -and -not [string]::IsNullOrWhiteSpace([string]$Given[$name])
    }

    $profileValues = @{}
    $profileParam = [string]$Scenario.profileParameter
    if ($profileParam) {
        $profileDef = @($defs | Where-Object { $_.name -eq $profileParam }) | Select-Object -First 1
        if ($profileDef) {
            $profileName = $profileDef.default
            if (& $isGiven $profileParam) { $profileName = $Given[$profileParam] }
            $profileName = ConvertTo-TtxParameterValue -Definition $profileDef -Value $profileName
            $profiles = Get-TtxScenarioProfiles -Scenario $Scenario
            if ($profiles[$profileName] -is [hashtable]) { $profileValues = $profiles[$profileName] }
        }
    }

    $resolved = @{}
    foreach ($def in $defs) {
        $value = $def.default
        if ($profileValues.ContainsKey($def.name)) { $value = $profileValues[$def.name] }
        if (& $isGiven $def.name) { $value = $Given[$def.name] }
        $resolved[$def.name] = ConvertTo-TtxParameterValue -Definition $def -Value $value
    }
    return $resolved
}

function Get-TtxStringList {
    param($Value)
    return , @(@($Value) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

# Validates a scenario. Problems come in three kinds:
#   errors     - the file is wrong; it can't be saved or loaded
#   incomplete - fine to save as a draft, but can't be loaded yet
#                (e.g. a step with no atomic_guid chosen)
#   warnings   - shown to the facilitator; nothing is blocked
function Test-TtxScenario {
    param([hashtable]$Scenario, [string]$Id)
    $errors = @()
    $incomplete = @()
    $warnings = @()
    if ($Scenario.schemaVersion -ne 2) { $errors += 'schemaVersion must be 2.' }
    if ([string]$Scenario.id -notmatch $script:IdPattern) { $errors += 'id is missing or invalid (letters, digits, - and _).' }
    elseif ($Id -and $Scenario.id -ne $Id) { $errors += "id '$($Scenario.id)' must match the file name '$Id.json'." }
    if ([string]::IsNullOrWhiteSpace([string]$Scenario.name)) { $errors += 'name is required.' }
    $steps = @($Scenario.steps | Where-Object { $null -ne $_ })
    if ($steps.Count -eq 0) { $incomplete += 'The scenario has no steps yet.' }
    $catalogReady = ($script:Ttx.Catalog.status -eq 'ready')
    $seen = @{}
    foreach ($step in $steps) {
        if ($step -isnot [hashtable]) { $errors += 'Each step must be an object.'; continue }
        $sid = [string]$step.id
        if ($sid -notmatch $script:IdPattern) { $errors += "Step id '$sid' is invalid."; continue }
        if ($seen.ContainsKey($sid)) { $errors += "Duplicate step id '$sid'." }
        if ([string]::IsNullOrWhiteSpace([string]$step.title)) { $errors += "Step '$sid' needs a title." }
        foreach ($dep in (Get-TtxStringList $step.depends_on)) {
            if (-not $seen.ContainsKey($dep) -or $dep -eq $sid) {
                $errors += "Step '$sid' depends on '$dep', which must be an earlier step."
            }
        }
        $seen[$sid] = $true
        foreach ($c in @($step.verify | Where-Object { $null -ne $_ })) {
            foreach ($p in (Test-TtxVerifyDefinition $c)) { $errors += "Step '$sid' verify: $p." }
            if ($c -is [hashtable]) {
                foreach ($k in @($c.Keys)) {
                    if ([string]$c[$k] -match '^\s*<.*>\s*$') { $incomplete += "Step '$sid' verify $($c.type): replace the placeholder $k '$($c[$k])'." }
                }
            }
        }
        foreach ($f in 'expected_detections', 'hunt_notes') {
            if ($null -ne $step[$f] -and @($step[$f] | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                $errors += "Step '$sid' $f must be a list of strings."
            }
        }

        if ($step.module) {
            # Stub module step (engine tests).
            $mod = [string]$step.module
            if ($mod -notmatch $script:IdPattern) { $errors += "Step '$sid' has an invalid module id." }
            elseif (-not (Test-Path -LiteralPath (Get-TtxModulePath $mod) -PathType Leaf)) {
                $errors += "Step '$sid' uses module '$mod', which does not exist."
            }
            continue
        }

        # ART step.
        $tech = ([string]$step.technique).Trim().ToUpperInvariant()
        if ($tech -and $tech -notmatch $script:TechniquePattern) { $errors += "Step '$sid' technique '$tech' is not an ATT&CK id like T1053.005." }
        if ($null -ne $step.input_arguments -and $step.input_arguments -isnot [hashtable]) { $errors += "Step '$sid' input_arguments must be an object." }
        $guid = ([string]$step.atomic_guid).Trim()
        $test = $null
        if (-not $guid) {
            $incomplete += "Step '$sid' has no atomic_guid yet. Choose a test from the catalog on the lab host."
        }
        elseif ($guid -notmatch $script:GuidPattern) {
            $errors += "Step '$sid' atomic_guid '$guid' is not a GUID."
        }
        else {
            $test = Get-TtxCatalogTest -Guid $guid
            if (-not $test) {
                if ($catalogReady) { $warnings += "Step '$sid': test $guid was not found in the installed atomics ($($script:Ttx.ArtRoot)). It can't run until it is." }
                else { $warnings += "Step '$sid': the ART catalog isn't loaded, so test $guid can't be checked yet." }
            }
            else {
                if ($tech -and $tech -ne $test.techniqueId) { $warnings += "Step '$sid' says technique $tech but test $guid belongs to $($test.techniqueId); $($test.techniqueId) is used." }
                if ($step.input_arguments -is [hashtable]) {
                    $known = @($test.inputArguments | ForEach-Object { $_.name })
                    foreach ($k in @($step.input_arguments.Keys)) {
                        if ($known -notcontains $k) { $warnings += "Step '$sid' input argument '$k' is not defined by the atomic and will be ignored." }
                    }
                }
            }
        }
        if (-not $tech -and -not $test) { $incomplete += "Step '$sid' needs a technique." }

        # Destructive/high-impact guardrail: needs the technique id typed back.
        $impactTech = if ($test) { [string]$test.techniqueId } else { $tech }
        if ((Test-TtxHighImpactTechnique $impactTech) -or ($test -and $test.highImpact)) {
            $typed = ([string]$step.high_impact_confirmation).Trim().ToUpperInvariant()
            if ($typed -ne $impactTech.ToUpperInvariant()) {
                $errors += "Step '$sid' uses $impactTech, a destructive/high-impact technique. Set high_impact_confirmation to '$impactTech' (typed confirmation) to include it."
            }
        }
    }
    return @{ errors = $errors; incomplete = $incomplete; warnings = $warnings }
}

function Read-TtxScenario {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -notmatch $script:IdPattern) { return $null }
    $path = Get-TtxScenarioPath $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $scenario = $null
    $check = @{ errors = @(); incomplete = @(); warnings = @() }
    try {
        $scenario = ConvertFrom-TtxJson -Json (Read-TtxTextFile -Path $path)
        if ($scenario -isnot [hashtable]) { throw 'the file must contain a JSON object.' }
        $check = Test-TtxScenario -Scenario $scenario -Id $Id
    }
    catch {
        $check.errors = @("Could not read $Id.json: $($_.Exception.Message)")
    }
    return @{ id = $Id; scenario = $scenario; errors = $check.errors; incomplete = $check.incomplete; warnings = $check.warnings }
}

function Get-TtxScenarioList {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:Ttx.ScenariosDir)) { return , $list }
    foreach ($file in @(Get-ChildItem -LiteralPath $script:Ttx.ScenariosDir -File -Filter '*.json' | Sort-Object Name)) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $entry = Read-TtxScenario -Id $id
        if ($null -eq $entry) { continue }
        $s = $entry.scenario
        $item = @{
            id               = $id
            name             = $id
            summary          = ''
            objectives       = @()
            parameters       = @()
            profileParameter = ''
            profiles         = @{}
            stepCount        = 0
            valid            = ($entry.errors.Count -eq 0)
            loadable         = ($entry.errors.Count -eq 0 -and $entry.incomplete.Count -eq 0)
            errors           = $entry.errors
            incomplete       = $entry.incomplete
            warnings         = $entry.warnings
        }
        if ($s -is [hashtable]) {
            # Assigned one by one: an @() inside an if-expression would unroll.
            if ($s.name) { $item.name = [string]$s.name }
            $item.summary = [string]$s.summary
            $item.objectives = Get-TtxStringList $s.objectives
            $item.stepCount = @($s.steps | Where-Object { $null -ne $_ }).Count
            if ($item.valid) {
                $item.parameters = Get-TtxScenarioParameters -Scenario $s
                $item.profileParameter = [string]$s.profileParameter
                $item.profiles = Get-TtxScenarioProfiles -Scenario $s
            }
        }
        $list += , $item
    }
    return , $list
}

function Get-TtxScenario {
    param([Parameter(Mandatory = $true)][string]$Id)
    $entry = Read-TtxScenario -Id $Id
    if ($null -eq $entry) { throw (New-TtxNotFound "Scenario '$Id' not found.") }
    return $entry
}

# Keeps only the fields the scenario format defines, so the builder can't
# write arbitrary data into scenarios/.
function ConvertTo-TtxCleanScenario {
    param([hashtable]$Scenario)
    $steps = @(foreach ($st in @($Scenario.steps | Where-Object { $_ -is [hashtable] })) {
            $out = [ordered]@{
                id    = ([string]$st.id).Trim()
                title = ([string]$st.title).Trim()
            }
            if ($st.module) {
                $out.module = [string]$st.module
                $out.params = if ($st.params -is [hashtable]) { $st.params } else { @{} }
            }
            else {
                $out.tactic = ([string]$st.tactic).Trim()
                $out.technique = ([string]$st.technique).Trim().ToUpperInvariant()
                $out.atomic_guid = ([string]$st.atomic_guid).Trim().ToLowerInvariant()
                $ia = [ordered]@{}
                if ($st.input_arguments -is [hashtable]) {
                    foreach ($k in @($st.input_arguments.Keys | Sort-Object)) { $ia[[string]$k] = [string]$st.input_arguments[$k] }
                }
                $out.input_arguments = $ia
                if ($st.high_impact_confirmation) { $out.high_impact_confirmation = ([string]$st.high_impact_confirmation).Trim().ToUpperInvariant() }
            }
            $out.depends_on = Get-TtxStringList $st.depends_on
            $out.verify = @(foreach ($c in @($st.verify | Where-Object { $_ -is [hashtable] })) {
                    $cc = [ordered]@{ type = [string]$c.type }
                    foreach ($k in @($c.Keys | Sort-Object)) { if ($k -ne 'type' -and $null -ne $c[$k] -and [string]$c[$k] -ne '') { $cc[$k] = [string]$c[$k] } }
                    $cc
                })
            $out.expected_detections = Get-TtxStringList $st.expected_detections
            $out.hunt_notes = Get-TtxStringList $st.hunt_notes
            if ($st.notes) { $out.notes = [string]$st.notes }
            $out
        })
    $clean = [ordered]@{
        schemaVersion = 2
        id            = ([string]$Scenario.id).Trim()
        name          = ([string]$Scenario.name).Trim()
        summary       = ([string]$Scenario.summary).Trim()
        objectives    = Get-TtxStringList $Scenario.objectives
    }
    if ($Scenario.notes) { $clean.notes = Get-TtxStringList $Scenario.notes }
    if ($Scenario.parameters) { $clean.parameters = @($Scenario.parameters) }
    if ($Scenario.profileParameter) { $clean.profileParameter = [string]$Scenario.profileParameter; $clean.profiles = $Scenario.profiles }
    $clean.steps = $steps
    return $clean
}

# Saves a scenario from the builder to scenarios/<id>.json. Refused if it has
# errors; drafts that are only incomplete (e.g. no GUID yet) are saved.
function Save-TtxScenario {
    param([hashtable]$Scenario, [bool]$Overwrite)
    if ($Scenario -isnot [hashtable]) { throw (New-TtxBadRequest 'scenario must be an object.') }
    $Scenario.schemaVersion = 2
    $clean = ConvertTo-TtxCleanScenario -Scenario $Scenario
    # Re-read through JSON so validation sees exactly what will be written.
    $json = ConvertTo-TtxJson -InputObject $clean
    $check = Test-TtxScenario -Scenario (ConvertFrom-TtxJson -Json $json) -Id ([string]$clean.id)
    if ($check.errors.Count -gt 0) {
        throw (New-TtxBadRequest ('Scenario not saved: ' + ($check.errors -join ' ')))
    }
    $path = Get-TtxScenarioPath ([string]$clean.id)
    if ((Test-Path -LiteralPath $path) -and -not $Overwrite) {
        throw (New-TtxConflict "A scenario with id '$($clean.id)' already exists. Save with overwrite to replace it.")
    }
    if (-not (Test-Path -LiteralPath $script:Ttx.ScenariosDir)) { New-Item -ItemType Directory -Path $script:Ttx.ScenariosDir | Out-Null }
    Write-TtxTextFile -Path $path -Text $json
    return @{ id = $clean.id; path = $path; saved = $true; errors = @(); incomplete = $check.incomplete; warnings = $check.warnings }
}

#endregion

#region Running steps

function Get-TtxStepContext {
    param([hashtable]$Step)
    $s = $script:Ttx.Session
    $params = @{}
    foreach ($key in @($s.parameters.Keys)) { $params[$key] = $s.parameters[$key] }
    if ($Step.params) {
        foreach ($key in @($Step.params.Keys)) { $params[$key] = $Step.params[$key] }
    }
    # Data every step recorded, so a step (and Cleanup after a restart) can use
    # what earlier runs created.
    $allData = @{}
    foreach ($st in $s.steps) {
        if ($st.data -is [hashtable]) { $allData[$st.id] = $st.data } else { $allData[$st.id] = @{} }
    }
    return @{
        SessionId    = $s.sessionId
        ScenarioId   = $s.scenarioId
        StepId       = $Step.id
        ArtifactRoot = $s.artifactRoot
        Parameters   = $params
        StepData     = $allData[$Step.id]
        AllStepData  = $allData
    }
}

# Context for server/ArtRunner.ps1, built only from saved session state so it
# works after a restart (D15).
function Get-TtxArtContext {
    param([hashtable]$Step)
    $s = $script:Ttx.Session
    $startUtc = $null
    if ($Step.run) { $startUtc = $Step.run.startUtc }
    return @{
        modulePath        = $s.art.modulePath
        atomicsPath       = $s.art.atomicsPath
        technique         = $Step.atomic.techniqueId
        guid              = $Step.atomic.guid
        inputArgs         = $Step.inputArguments
        values            = $Step.values
        elevationRequired = [bool]$Step.atomic.elevationRequired
        hasCleanup        = [bool]$Step.atomic.hasCleanup
        timeoutSeconds    = $script:Ttx.StepTimeoutSec
        executionLogPath  = (Join-Path (Get-TtxSessionDir) 'art-execution-log.csv')
        verify            = @($Step.verify)
        stepStartUtc      = $startUtc
        previousVerify    = @($Step.verifyResults)
    }
}

# Runs the step runner's 'describe' operation synchronously in a fresh runspace.
function Invoke-TtxDescribe {
    param([hashtable]$Step)
    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        $contextJson = ConvertTo-TtxJson -InputObject (Get-TtxStepContext -Step $Step) -Compress
        [void]$ps.AddCommand($script:Ttx.RunnerPath)
        [void]$ps.AddParameter('ModulePath', (Get-TtxModulePath $Step.module))
        [void]$ps.AddParameter('Operation', 'describe')
        [void]$ps.AddParameter('ContextJson', $contextJson)
        $out = @($ps.Invoke())
        $json = $out | Where-Object { $_ -is [string] } | Select-Object -Last 1
        if (-not $json) {
            $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
            if (-not $msg) { $msg = 'Step runner produced no result.' }
            return @{ ok = $false; error = $msg }
        }
        return ConvertFrom-TtxJson -Json $json
    }
    finally {
        $ps.Dispose()
    }
}

# Steps this step depends on that haven't succeeded.
function Get-TtxUnmetDependencies {
    param([hashtable]$Step)
    $missing = @()
    foreach ($dep in @($Step.dependsOn)) {
        $d = Get-TtxStep -StepId $dep
        if ($d -and $d.status -ne 'succeeded') { $missing += , $d }
    }
    return , $missing
}

# Why a step can't run right now (other than dependencies), or $null.
function Get-TtxStepBlocker {
    param([hashtable]$Step)
    if ($Step.kind -eq 'module') {
        if ($Step.describeError) { return "Module '$($Step.module)' could not be loaded: $($Step.describeError)" }
        return $null
    }
    if (-not $Step.atomic) {
        return "Test $($Step.atomicGuid) was not found in the installed atomics at $($script:Ttx.Session.art.atomicsPath). Choose another test or update ART."
    }
    if (-not (Test-Path -LiteralPath $script:Ttx.Session.art.modulePath -PathType Leaf)) {
        return "The ART module was not found at $($script:Ttx.Session.art.modulePath)."
    }
    if ($Step.atomic.elevationRequired -and -not $script:Ttx.Session.preflight.elevated) {
        return "'$($Step.atomic.testName)' requires elevation (elevation_required) and the control center is not running as administrator. Restart it from an elevated PowerShell to run this step."
    }
    return $null
}

function Start-TtxNextJob {
    if ($script:Ttx.Job -or $script:Ttx.Queue.Count -eq 0) { return }
    $item = $script:Ttx.Queue[0]
    $script:Ttx.Queue.RemoveAt(0)
    $step = Get-TtxStep -StepId $item.stepId

    if ($item.op -eq 'run') {
        # Re-checked when the step's turn comes (e.g. in Run all).
        $missing = Get-TtxUnmetDependencies -Step $step
        if ($missing.Count -gt 0) {
            $names = ($missing | ForEach-Object { "'$($_.title)' ($($_.status))" }) -join ', '
            $step.status = 'pending'
            Add-TtxEvent -StepId $step.id -Level warn -Message "Not run: it requires $names to succeed first."
            Clear-TtxRunQueue -Reason 'Stopped to keep dependency order.'
            Save-TtxSession
            Start-TtxNextJob
            return
        }
    }

    $script:Ttx.JobTimeoutSec = $script:Ttx.StepTimeoutSec
    if ($step.kind -eq 'module') {
        $contextJson = ConvertTo-TtxJson -InputObject (Get-TtxStepContext -Step $step) -Compress
        $script:Ttx.Job = Start-Job -ArgumentList $script:Ttx.RunnerPath, (Get-TtxModulePath $step.module), $item.op, $contextJson -ScriptBlock {
            param($RunnerPath, $ModulePath, $Operation, $ContextJson)
            & $RunnerPath -ModulePath $ModulePath -Operation $Operation -ContextJson $ContextJson
        }
        if ($step.info -and [int]$step.info.timeoutSeconds -gt $script:Ttx.JobTimeoutSec) {
            $script:Ttx.JobTimeoutSec = [int]$step.info.timeoutSeconds
        }
    }
    else {
        if ($item.op -eq 'run') {
            # Recorded before the job starts: the window for verify checks and
            # the answer key starts here.
            $step.run = @{ startUtc = (Get-TtxUtcNow); endUtc = $null; exitCode = $null; output = $null; command = $step.atomic.command }
        }
        $contextJson = ConvertTo-TtxJson -InputObject (Get-TtxArtContext -Step $step) -Compress
        $script:Ttx.Job = Start-Job -ArgumentList $script:Ttx.ArtRunnerPath, $item.op, $contextJson -ScriptBlock {
            param($RunnerPath, $Operation, $ContextJson)
            & $RunnerPath -Operation $Operation -ContextJson $ContextJson
        }
        # Module import and the prereq check add time on top of the test itself;
        # GetPrereqs may download several files.
        $script:Ttx.JobTimeoutSec = $script:Ttx.StepTimeoutSec + 90
        if ($item.op -eq 'getprereqs') { $script:Ttx.JobTimeoutSec = ($script:Ttx.StepTimeoutSec * 4) + 90 }
    }
    $script:Ttx.JobItem = $item
    $script:Ttx.JobStarted = Get-Date

    $step.startedAt = (Get-Date).ToString('o')
    $step.finishedAt = $null
    $step.error = $null
    $step.lastOp = $item.op
    switch ($item.op) {
        'run' {
            $step.status = 'running'
            # Marked before anything runs, so an interrupted run is still cleaned up.
            $step.executed = $true
            Add-TtxEvent -StepId $step.id -Message "Running: $($step.title)"
        }
        'getprereqs' {
            $step.status = 'getting-prereqs'
            Add-TtxEvent -StepId $step.id -Message "Getting prerequisites (admin confirmed): $($step.title)"
        }
        'cleanup' {
            $step.status = 'cleaning'
            $step.cleanup = @{ status = 'running'; atUtc = (Get-TtxUtcNow); output = $null; remaining = @(); error = $null }
            Add-TtxEvent -StepId $step.id -Message "Cleaning up: $($step.title)"
        }
    }
    Save-TtxSession
}

function Complete-TtxJob {
    param([string]$TimeoutMessage)

    $job = $script:Ttx.Job
    $item = $script:Ttx.JobItem
    $step = Get-TtxStep -StepId $item.stepId

    $jobErrors = $null
    if ($TimeoutMessage) { Stop-Job -Job $job }
    $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
    $reason = $null
    if ($job.State -eq 'Failed' -and $job.ChildJobs.Count -gt 0 -and $job.ChildJobs[0].JobStateInfo.Reason) {
        $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message
    }
    Remove-Job -Job $job -Force
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null
    $script:Ttx.JobStarted = $null

    $result = $null
    $json = $out | Where-Object { $_ -is [string] -and $_.StartsWith('{') } | Select-Object -Last 1
    if ($json) {
        try { $result = ConvertFrom-TtxJson -Json $json } catch { $result = $null }
    }
    $crashed = ($null -eq $result)
    if ($crashed) {
        $msg = $TimeoutMessage
        if (-not $msg) { $msg = $reason }
        if (-not $msg -and $jobErrors) { $msg = ($jobErrors | ForEach-Object { $_.ToString() }) -join '; ' }
        if (-not $msg) { $msg = 'Step runner produced no result.' }
        $result = @{ ok = $false; error = $msg; verify = $null; logs = @(); artifacts = @(); pid = $null; data = $null }
    }

    $step.finishedAt = (Get-Date).ToString('o')
    $step.error = $result.error
    $ok = [bool]$result.ok

    if ($step.kind -eq 'module') { Complete-TtxModuleJob -Step $step -Op $item.op -Result $result -Ok $ok }
    else { Complete-TtxArtJob -Step $step -Op $item.op -Result $result -Ok $ok -Crashed $crashed }

    if ($item.op -eq 'cleanup') {
        $moreCleanup = @($script:Ttx.Queue | Where-Object { $_.op -eq 'cleanup' }).Count -gt 0
        if (-not $moreCleanup) { Complete-TtxCleanup }
    }
    Save-TtxSession
    Write-TtxAnswerKey
}

function Complete-TtxModuleJob {
    param([hashtable]$Step, [string]$Op, [hashtable]$Result, [bool]$Ok)
    foreach ($log in @($Result.logs)) {
        if ($null -eq $log) { continue }
        $level = if ($log.level -in 'info', 'warn', 'error') { $log.level } else { 'info' }
        Add-TtxEvent -StepId $Step.id -Level $level -Message ([string]$log.message) -Timestamp ([string]$log.ts)
    }
    $Step.verify = $Result.verify
    # Data the module recorded (e.g. what it created); Cleanup relies on it.
    if ($Result.data -is [hashtable]) { $Step.data = $Result.data }
    if ($Op -eq 'run') {
        $Step.artifacts = @($Result.artifacts | Where-Object { $null -ne $_ })
        $Step.runnerPid = $Result.pid
        foreach ($a in $Step.artifacts) {
            Add-TtxEvent -StepId $Step.id -Message "Artifact ($($a.type)): $($a.location)"
        }
        if ($Ok) {
            $Step.status = 'succeeded'
            Add-TtxEvent -StepId $Step.id -Message "Succeeded. Verify: $($Result.verify.detail)"
        }
        else {
            $Step.status = 'failed'
            Add-TtxEvent -StepId $Step.id -Level error -Message "Failed: $($Result.error)"
            Clear-TtxRunQueue -Reason "Stopped after '$($Step.id)' failed."
        }
    }
    else {
        $Step.cleanup = @{ status = $(if ($Ok) { 'succeeded' } else { 'failed' }); atUtc = (Get-TtxUtcNow); output = [string]$Result.verify.detail; remaining = @(); error = $Result.error }
        if ($Ok) {
            $Step.status = 'cleaned'
            Add-TtxEvent -StepId $Step.id -Message "Cleaned up. Verify: $($Result.verify.detail)"
        }
        else {
            $Step.status = 'cleanup-failed'
            Add-TtxEvent -StepId $Step.id -Level error -Message "Cleanup failed: $($Result.error)"
        }
    }
}

function Complete-TtxArtJob {
    param([hashtable]$Step, [string]$Op, [hashtable]$Result, [bool]$Ok, [bool]$Crashed)
    if ($Result.prereqs -is [hashtable]) { $Step.prereqs = $Result.prereqs }

    switch ($Op) {
        'run' {
            $prereqsMissing = (-not $Crashed -and $Result.prereqs -and $Result.prereqs.status -eq 'missing' -and -not $Result.run)
            if ($prereqsMissing) {
                # Nothing executed; only the prereq check ran.
                $Step.executed = $false
                $Step.run = $null
                $Step.status = 'prereqs-missing'
                $Step.error = $null
                $what = if ($Step.atomic.prereqDownloads) { ' Some prereqs download files from the internet.' } else { '' }
                Add-TtxEvent -StepId $Step.id -Level warn -Message "Prerequisites not met: $(@($Result.prereqs.missing) -join '; '). Review what GetPrereqs would do and confirm it to continue.$what"
                Clear-TtxRunQueue -Reason "Stopped at '$($Step.id)': prerequisites are missing."
                return
            }
            if ($Result.run -is [hashtable]) {
                $r = $Result.run
                $Step.run.endUtc = $r.endUtc
                $Step.run.exitCode = $r.exitCode
                $Step.run.exitCodeSource = $r.exitCodeSource
                $Step.run.artExecuted = $r.executed
                $Step.run.output = $r.output
                $Step.run.logPath = $r.logPath
                $Step.run.artStartUtc = $r.startUtc
            }
            elseif ($Step.run) {
                $Step.run.endUtc = Get-TtxUtcNow
            }
            $Step.verifyResults = @($Result.verify | Where-Object { $null -ne $_ })
            foreach ($v in $Step.verifyResults) {
                $lvl = if ($v.result -eq 'fail') { 'warn' } else { 'info' }
                Add-TtxEvent -StepId $Step.id -Level $lvl -Message "Verify $($v.type) $($v.target): $($v.result). $($v.detail)"
            }
            if ($Ok) {
                $Step.status = 'succeeded'
                $code = if ($null -ne $Step.run.exitCode) { "exit code $($Step.run.exitCode)" } else { 'no exit code reported' }
                Add-TtxEvent -StepId $Step.id -Message "Succeeded ($code)."
            }
            else {
                $Step.status = 'failed'
                Add-TtxEvent -StepId $Step.id -Level error -Message "Failed: $($Result.error)"
                Clear-TtxRunQueue -Reason "Stopped after '$($Step.id)' failed."
            }
        }
        'getprereqs' {
            if ($Result.getPrereqs -is [hashtable]) {
                $Step.getPrereqs = $Result.getPrereqs
                $Step.getPrereqs.confirmedAtUtc = $Step.getPrereqsConfirmedAtUtc
            }
            $Step.prereqsFetched = $true
            if ($Ok) {
                $Step.status = 'pending'
                Add-TtxEvent -StepId $Step.id -Message 'Prerequisites are now met. Press Run to execute the step.'
            }
            else {
                $Step.status = 'prereqs-missing'
                Add-TtxEvent -StepId $Step.id -Level error -Message "GetPrereqs did not satisfy the prerequisites: $($Result.error)"
            }
        }
        'cleanup' {
            $Step.verifyAfterCleanup = @($Result.verify | Where-Object { $null -ne $_ })
            $output = $null
            $remaining = @()
            if ($Result.cleanup -is [hashtable]) { $output = $Result.cleanup.output; $remaining = @($Result.cleanup.remaining | Where-Object { $null -ne $_ }) }
            $Step.cleanup = @{
                status    = $(if ($Ok) { 'succeeded' } else { 'failed' })
                atUtc     = (Get-TtxUtcNow)
                output    = $output
                remaining = $remaining
                error     = $Result.error
            }
            if ($Ok) {
                $Step.status = 'cleaned'
                Add-TtxEvent -StepId $Step.id -Message 'Cleaned up (ART -Cleanup ran; verify checks confirm the artifacts are gone).'
            }
            else {
                $Step.status = 'cleanup-failed'
                Add-TtxEvent -StepId $Step.id -Level error -Message "Cleanup failed: $($Result.error)"
            }
        }
    }
}

# Drops queued 'run' items (e.g. Run all after a failure) and resets their steps.
function Clear-TtxRunQueue {
    param([string]$Reason)
    $dropped = @($script:Ttx.Queue | Where-Object { $_.op -eq 'run' })
    if ($dropped.Count -eq 0) { return }
    foreach ($item in $dropped) {
        [void]$script:Ttx.Queue.Remove($item)
        $step = Get-TtxStep -StepId $item.stepId
        $step.status = 'pending'
    }
    Add-TtxEvent -Level warn -Message "$Reason $($dropped.Count) queued step(s) were not run."
}

# After all cleanup operations have finished: remove the now-empty artifact
# folders and close the session if every executed step cleaned up.
function Complete-TtxCleanup {
    $s = $script:Ttx.Session
    $failed = @($s.steps | Where-Object { $_.executed -and (-not $_.cleanup -or $_.cleanup.status -ne 'succeeded') })
    if ($failed.Count -gt 0) {
        Add-TtxEvent -Level error -Message "Cleanup incomplete: $($failed.Count) step(s) did not clean up. Fix the cause and press Cleanup again."
        return
    }
    if ($s.artifactRoot) { Remove-TtxEmptyArtifactFolders }
    if (@($s.steps | Where-Object { $_.prereqsFetched }).Count -gt 0) {
        Add-TtxEvent -Level warn -Message 'Note: files fetched by GetPrereqs are not removed by ART cleanup (usually under the atomics ExternalPayloads folder).'
    }
    $s.status = 'cleaned'
    Add-TtxEvent -Message 'Cleanup complete; session closed.'
}

# Removes the stub artifact folder and any empty ArtifactFolder parents, never
# going above %ProgramData% and never deleting a folder that still has content.
function Remove-TtxEmptyArtifactFolders {
    $s = $script:Ttx.Session
    if ([string]::IsNullOrEmpty($env:ProgramData)) { return }
    $base = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\', '/')
    $dir = [System.IO.Path]::GetFullPath($s.artifactRoot)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    while ($dir.StartsWith($base + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $children = @(Get-ChildItem -LiteralPath $dir -Force)
            if ($children.Count -gt 0) {
                if ($dir -eq [System.IO.Path]::GetFullPath($s.artifactRoot)) {
                    Add-TtxEvent -Level warn -Message "Left $dir in place: it still contains $($children.Count) item(s) the steps did not create."
                }
                break
            }
            Remove-Item -LiteralPath $dir -Force
            Add-TtxEvent -Message "Removed empty folder $dir"
        }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
}

#endregion

#region Public API

function Initialize-TtxEngine {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$StepTimeoutSec = 120,
        [string]$ArtRoot,
        [int]$TelemetryDelayMinutes = 5
    )
    $script:Ttx.Root = $Root
    $script:Ttx.RunsDir = Join-Path $Root 'runs'
    $script:Ttx.ScenariosDir = Join-Path $Root 'scenarios'
    $script:Ttx.ModulesDir = Join-Path $Root 'modules'
    $script:Ttx.RunnerPath = Join-Path (Join-Path $Root 'server') 'StepRunner.ps1'
    $script:Ttx.ArtRunnerPath = Join-Path (Join-Path $Root 'server') 'ArtRunner.ps1'
    $script:Ttx.CatalogBuilderPath = Join-Path (Join-Path $Root 'server') 'CatalogBuilder.ps1'
    $script:Ttx.CatalogPath = Join-Path $script:Ttx.RunsDir 'catalog.json'
    $script:Ttx.ArtRoot = Resolve-TtxArtRoot $ArtRoot
    $script:Ttx.StepTimeoutSec = $StepTimeoutSec
    $script:Ttx.TelemetryDelayMin = $TelemetryDelayMinutes
    $script:Ttx.Session = $null
    $script:Ttx.Events.Clear()
    $script:Ttx.Queue.Clear()
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null
    $script:Ttx.CatalogJob = $null

    if (-not (Test-Path -LiteralPath $script:Ttx.RunsDir)) {
        New-Item -ItemType Directory -Path $script:Ttx.RunsDir | Out-Null
    }
    Initialize-TtxCatalog
    Restore-TtxSession
}

# Reloads the most recent session that has not been cleaned up, so Cleanup
# still works after the server restarts (everything it needs is in state.json).
function Restore-TtxSession {
    $dirs = @(Get-ChildItem -LiteralPath $script:Ttx.RunsDir -Directory | Sort-Object Name -Descending)
    foreach ($dir in $dirs) {
        $statePath = Join-Path $dir.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try {
            $state = ConvertFrom-TtxJson -Json (Read-TtxTextFile -Path $statePath)
        }
        catch {
            Write-Warning "Skipping unreadable session state $statePath : $($_.Exception.Message)"
            continue
        }
        if ($state.status -ne 'active') { continue }

        $script:Ttx.Session = $state
        $eventsPath = Join-Path $dir.FullName 'events.jsonl'
        if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($eventsPath, [System.Text.Encoding]::UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $evt = ConvertFrom-TtxJson -Json $line
                    $evt.seq = $script:Ttx.Events.Count
                    [void]$script:Ttx.Events.Add($evt)
                }
                catch {
                    Write-Warning "Skipping unreadable line in $eventsPath"
                }
            }
        }
        Add-TtxEvent -Message "Server restarted; restored session $($state.sessionId)."
        if ($state.art -and $state.art.root -and $state.art.root -ne $script:Ttx.ArtRoot) {
            Add-TtxEvent -Level warn -Message "This session was started with ART at $($state.art.root); the control center is now configured for $($script:Ttx.ArtRoot). The session keeps using $($state.art.root)."
        }
        foreach ($step in $state.steps) {
            switch ($step.status) {
                'queued' { $step.status = 'pending' }
                'cleanup-queued' { $step.status = 'interrupted'; if ($step.cleanup) { $step.cleanup.status = 'interrupted' } }
                'getting-prereqs' {
                    $step.status = 'prereqs-missing'
                    Add-TtxEvent -StepId $step.id -Level warn -Message 'GetPrereqs was in progress when the server stopped. Check prerequisites again.'
                }
                { $_ -in 'running', 'cleaning' } {
                    if ($step.cleanup -and $step.cleanup.status -eq 'running') { $step.cleanup.status = 'interrupted' }
                    $step.status = 'interrupted'
                    Add-TtxEvent -StepId $step.id -Level warn -Message 'Was in progress when the server stopped; marked interrupted. Run Cleanup to be safe.'
                }
            }
        }
        Save-TtxSession
        return
    }
}

function ConvertTo-TtxSessionStep {
    param([hashtable]$Def, [hashtable]$Session)
    $step = @{
        id                 = [string]$Def.id
        title              = [string]$Def.title
        kind               = $(if ($Def.module) { 'module' } else { 'atomic' })
        tactic             = [string]$Def.tactic
        technique          = ([string]$Def.technique).ToUpperInvariant()
        dependsOn          = Get-TtxStringList $Def.depends_on
        verify             = @($Def.verify | Where-Object { $null -ne $_ })
        expectedDetections = Get-TtxStringList $Def.expected_detections
        huntNotes          = Get-TtxStringList $Def.hunt_notes
        notes              = [string]$Def.notes
        status             = 'pending'
        executed           = $false
        detections         = @{}
        error              = $null
        startedAt          = $null
        finishedAt         = $null
        lastOp             = $null
        cleanup            = $null
        # ART steps
        atomicGuid         = ([string]$Def.atomic_guid).Trim().ToLowerInvariant()
        inputArguments     = $(if ($Def.input_arguments -is [hashtable]) { $Def.input_arguments } else { @{} })
        values             = @{}
        atomic             = $null
        prereqs            = $null
        getPrereqs         = $null
        prereqsFetched     = $false
        run                = $null
        verifyResults      = @()
        verifyAfterCleanup = @()
        # Stub module steps
        module             = [string]$Def.module
        params             = $(if ($Def.params -is [hashtable]) { $Def.params } else { @{} })
        data               = @{}
        info               = $null
        hunt               = @()
        describeError      = $null
        artifacts          = @()
        runnerPid          = $null
    }
    if ($step.kind -eq 'module') { return $step }

    # Snapshot of the atomic as installed now: what will run, after
    # input-argument substitution. Saved in state.json with the session.
    $t = Get-TtxCatalogTest -Guid $step.atomicGuid
    if (-not $t) { return $step }
    $atomics = $Session.art.atomicsPath
    $values = Get-TtxResolvedInputArgs -Definitions $t.inputArguments -Overrides $step.inputArguments
    $step.values = $values
    if (-not $step.technique) { $step.technique = $t.techniqueId }
    $step.atomic = @{
        techniqueId       = $t.techniqueId
        techniqueName     = $t.techniqueName
        testNumber        = $t.testNumber
        testName          = $t.testName
        guid              = $t.guid
        description       = $t.description
        executor          = $t.executor
        elevationRequired = [bool]$t.elevationRequired
        platforms         = @($t.platforms)
        inputArguments    = @($t.inputArguments)
        command           = Expand-TtxAtomicCommand $t.command $values $atomics
        cleanupCommand    = Expand-TtxAtomicCommand $t.cleanupCommand $values $atomics
        hasCleanup        = -not [string]::IsNullOrWhiteSpace([string]$t.cleanupCommand)
        hasDependencies   = [bool]$t.hasDependencies
        dependencies      = @(foreach ($d in @($t.dependencies)) {
                if ($null -eq $d) { continue }
                @{
                    description      = Expand-TtxAtomicCommand $d.description $values $atomics
                    getPrereqCommand = Expand-TtxAtomicCommand $d.getPrereqCommand $values $atomics
                    downloads        = [bool]$d.downloads
                }
            })
        prereqDownloads   = [bool]$t.prereqDownloads
        commandDownloads  = [bool]$t.commandDownloads
        highImpact        = [bool]$t.highImpact
        yamlPath          = $t.yamlPath
    }
    return $step
}

function New-TtxSession {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioId,
        [hashtable]$Parameters = @{}
    )
    if (Test-TtxBusy) { throw (New-TtxConflict 'A step is running. Wait for it to finish or press Cleanup.') }
    $current = $script:Ttx.Session
    if ($current -and $current.status -eq 'active' -and (Test-TtxSessionTouched)) {
        throw (New-TtxConflict "Session $($current.sessionId) has steps that ran. Press Cleanup before loading another scenario.")
    }
    if ($ScenarioId -notmatch $script:IdPattern) { throw (New-TtxBadRequest 'Invalid scenario id.') }
    $entry = Read-TtxScenario -Id $ScenarioId
    if ($null -eq $entry) { throw (New-TtxNotFound "Scenario '$ScenarioId' not found.") }
    if ($entry.errors.Count -gt 0) { throw (New-TtxBadRequest ("Scenario '$ScenarioId' is invalid: " + ($entry.errors -join ' '))) }
    if ($entry.incomplete.Count -gt 0) { throw (New-TtxBadRequest ("Scenario '$ScenarioId' isn't ready to load: " + ($entry.incomplete -join ' '))) }
    $scenario = $entry.scenario
    $hasArtSteps = (@($scenario.steps | Where-Object { $_ -is [hashtable] -and -not $_.module }).Count -gt 0)
    if ($hasArtSteps -and $script:Ttx.Catalog.status -ne 'ready') {
        $why = if ($script:Ttx.Catalog.status -eq 'building') { 'it is still being built; try again in a minute' } else { [string]$script:Ttx.Catalog.error }
        throw (New-TtxConflict "The ART catalog isn't available ($why).")
    }

    # Resolve parameters: explicit value > profile value > default. Unknown names are ignored.
    $resolved = Resolve-TtxParameters -Scenario $scenario -Given $Parameters
    $artifactRoot = $null
    if ($resolved.ContainsKey('ArtifactFolder')) {
        $folder = ([string]$resolved.ArtifactFolder) -replace '^(%ProgramData%|\$env:ProgramData)[\\/]', ''
        $resolved.ArtifactFolder = $folder
        if ($folder -notmatch $script:FolderPattern -or $folder -match '(^|[\\/])\.\.?([\\/]|$)') {
            throw (New-TtxBadRequest "ArtifactFolder '$folder' must be a relative folder path (letters, digits, space, . _ -) with no '..'.")
        }
        if ([string]::IsNullOrEmpty($env:ProgramData)) { throw 'The ProgramData environment variable is not set.' }
        # Stub files go directly in the artifact folder (D16).
        $artifactRoot = Join-Path $env:ProgramData $folder
    }

    $sessionId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))

    if ($current -and $current.status -eq 'active') {
        $current.status = 'abandoned'
        Add-TtxEvent -Message 'Session replaced before any step ran.'
        Save-TtxSession
    }

    $paths = Get-TtxArtPaths -ArtRoot $script:Ttx.ArtRoot
    $preflight = Get-TtxPreflight -ArtRoot $script:Ttx.ArtRoot
    $session = @{
        schemaVersion   = 2
        sessionId       = $sessionId
        scenarioId      = [string]$scenario.id
        scenarioName    = [string]$scenario.name
        scenarioSummary = [string]$scenario.summary
        objectives      = Get-TtxStringList $scenario.objectives
        createdAt       = (Get-Date).ToString('o')
        updatedAt       = $null
        status          = 'active'
        parameters      = $resolved
        artifactRoot    = $artifactRoot
        # Recorded once so runs and cleanup (even after a restart) use the same install.
        art             = @{
            root        = $script:Ttx.ArtRoot
            modulePath  = $paths.modulePath
            atomicsPath = $paths.atomicsPath
            version     = $preflight.art.moduleVersion
        }
        preflight       = $preflight
        calibration     = $null
        steps           = @()
    }
    $session.steps = @(foreach ($st in @($scenario.steps | Where-Object { $null -ne $_ })) {
            ConvertTo-TtxSessionStep -Def $st -Session $session
        })

    $script:Ttx.Events.Clear()
    $script:Ttx.Session = $session
    New-Item -ItemType Directory -Path (Get-TtxSessionDir) -Force | Out-Null
    Save-TtxSession
    Add-TtxEvent -Message "Session $sessionId created for scenario '$($scenario.name)'."
    $pf = $session.preflight
    Add-TtxEvent -Message "Preflight: host $($pf.host), user $($pf.user), elevated $($pf.elevated), Falcon sensor $($pf.falconService), AID $(if ($pf.aid) { $pf.aid } else { 'unknown' })."
    $artMsg = if ($pf.art.moduleImportable) { "ART $($pf.art.moduleVersion) at $($pf.art.root)" } else { "ART not usable at $($pf.art.root)" }
    Add-TtxEvent -Message "Preflight: $artMsg; $($pf.art.techniqueCount) technique folder(s); powershell-yaml $(if ($pf.art.yamlAvailable) { $pf.art.yamlVersion } else { 'missing' })."
    foreach ($w in @($pf.warnings)) { Add-TtxEvent -Level warn -Message $w }
    foreach ($w in @($entry.warnings)) { Add-TtxEvent -Level warn -Message $w }

    foreach ($step in $session.steps) {
        if ($step.kind -eq 'module') {
            $d = Invoke-TtxDescribe -Step $step
            if ($d.ok) {
                $step.info = $d.info
                $step.hunt = @($d.hunt)
            }
            else {
                $step.describeError = $d.error
                Add-TtxEvent -StepId $step.id -Level error -Message "Could not load module '$($step.module)': $($d.error)"
            }
            continue
        }
        if (-not $step.atomic) {
            Add-TtxEvent -StepId $step.id -Level warn -Message "Test $($step.atomicGuid) is not in the installed atomics. This step can't run."
            continue
        }
        $blocker = Get-TtxStepBlocker -Step $step
        if ($blocker) { Add-TtxEvent -StepId $step.id -Level warn -Message $blocker }
    }
    Save-TtxSession
    Write-TtxAnswerKey
    return (Get-TtxSessionView)
}

function Get-TtxSessionView {
    param([int]$Since = 0, [int]$Revision = -1)
    $count = $script:Ttx.Events.Count
    if ($Since -lt 0 -or $Since -gt $count) { $Since = 0 }
    $current = $null
    if ($script:Ttx.JobItem) { $current = $script:Ttx.JobItem }

    # The session (and per-step extras) is only sent when it changed since the
    # revision the UI already has; events are always incremental.
    $unchanged = ($Revision -ge 0 -and $Revision -eq $script:Ttx.Revision -and $null -ne $script:Ttx.Session)
    $extras = @{}
    if ($script:Ttx.Session -and -not $unchanged) {
        foreach ($step in $script:Ttx.Session.steps) {
            $blockedBy = @(Get-TtxUnmetDependencies -Step $step | ForEach-Object { @{ id = $_.id; title = $_.title; status = $_.status } })
            $extras[$step.id] = @{
                detections = (Get-TtxStepDetectionRows -Step $step)
                blockedBy  = $blockedBy
                blocker    = (Get-TtxStepBlocker -Step $step)
                huntNotes  = (Get-TtxExpandedHuntNotes -Step $step)
            }
        }
    }
    return @{
        session      = $(if ($unchanged) { $null } else { $script:Ttx.Session })
        unchanged    = $unchanged
        revision     = $script:Ttx.Revision
        busy         = (Test-TtxBusy)
        current      = $current
        stepExtras   = $extras
        readyToHunt  = $(if ($script:Ttx.Session -and -not $unchanged) { Get-TtxReadyToHunt } else { $null })
        catalog      = (Get-TtxCatalogStatus)
        eventCount   = $count
        events       = @($script:Ttx.Events.GetRange($Since, $count - $Since))
    }
}

function Assert-TtxCanRun {
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    if ($s.status -ne 'active') { throw (New-TtxConflict 'This session is closed. Load a scenario to start a new one.') }
    if (Test-TtxBusy) { throw (New-TtxConflict 'A step is already running.') }
}

function Start-TtxStep {
    param([Parameter(Mandatory = $true)][string]$StepId)
    Assert-TtxCanRun
    $step = Get-TtxStep -StepId $StepId
    if (-not $step) { throw (New-TtxNotFound "Step '$StepId' not found.") }
    $missing = Get-TtxUnmetDependencies -Step $step
    if ($missing.Count -gt 0) {
        $names = ($missing | ForEach-Object { "'$($_.title)' ($($_.status))" }) -join ', '
        $msg = "Step '$($step.title)' can't run yet: it requires $names to succeed first."
        Add-TtxEvent -StepId $step.id -Level warn -Message $msg
        throw (New-TtxConflict $msg)
    }
    $blocker = Get-TtxStepBlocker -Step $step
    if ($blocker) {
        Add-TtxEvent -StepId $step.id -Level warn -Message $blocker
        throw (New-TtxConflict $blocker)
    }
    $step.status = 'queued'
    [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'run' })
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

# Queues every step that hasn't succeeded yet, in order. Refused up front if
# any of them can't run (e.g. needs elevation), so nothing half-runs.
function Start-TtxRunAll {
    Assert-TtxCanRun
    $todo = @($script:Ttx.Session.steps | Where-Object { $_.status -ne 'succeeded' })
    if ($todo.Count -eq 0) { throw (New-TtxConflict 'Every step has already succeeded.') }
    $blocked = @(foreach ($step in $todo) {
            $b = Get-TtxStepBlocker -Step $step
            if ($b) { "$($step.id): $b" }
        })
    if ($blocked.Count -gt 0) {
        $msg = 'Run all refused: ' + ($blocked -join ' ')
        Add-TtxEvent -Level warn -Message $msg
        throw (New-TtxConflict $msg)
    }
    foreach ($step in $todo) {
        $step.status = 'queued'
        [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'run' })
    }
    Add-TtxEvent -Message "Run all: $($todo.Count) step(s) queued."
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

# Runs ART -GetPrereqs for a step whose prerequisites are missing. It may
# download files, so it needs the admin's explicit confirmation, and a second
# acknowledgement when the prereq commands look like downloads.
function Start-TtxGetPrereqs {
    param(
        [Parameter(Mandatory = $true)][string]$StepId,
        [bool]$Confirm,
        [bool]$ConfirmDownload
    )
    Assert-TtxCanRun
    $step = Get-TtxStep -StepId $StepId
    if (-not $step) { throw (New-TtxNotFound "Step '$StepId' not found.") }
    if ($step.kind -ne 'atomic' -or -not $step.atomic) { throw (New-TtxBadRequest 'GetPrereqs only applies to ART steps.') }
    if (-not $step.atomic.hasDependencies) { throw (New-TtxConflict 'This atomic defines no prerequisites.') }
    $blocker = Get-TtxStepBlocker -Step $step
    if ($blocker) { throw (New-TtxConflict $blocker) }
    if (-not $Confirm) {
        throw (New-TtxBadRequest 'GetPrereqs needs explicit confirmation (confirm: true) after reviewing the commands it will run.')
    }
    if ($step.atomic.prereqDownloads -and -not $ConfirmDownload) {
        throw (New-TtxBadRequest 'These prereqs appear to download external files or tools. Confirm the download (confirmDownload: true) to continue.')
    }
    $step.getPrereqsConfirmedAtUtc = Get-TtxUtcNow
    $note = if ($step.atomic.prereqDownloads) { ' (download acknowledged)' } else { '' }
    Add-TtxEvent -StepId $step.id -Message "Admin confirmed GetPrereqs$note."
    $step.status = 'queued'
    [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'getprereqs' })
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

# Stops anything in progress, then cleans up every executed step in reverse
# order, from saved session state. Steps that never ran are skipped.
function Start-TtxCleanup {
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    if ($s.status -ne 'active') { throw (New-TtxConflict 'This session is already closed.') }
    if (@($script:Ttx.Queue | Where-Object { $_.op -eq 'cleanup' }).Count -gt 0 -or
        ($script:Ttx.JobItem -and $script:Ttx.JobItem.op -eq 'cleanup')) {
        throw (New-TtxConflict 'Cleanup is already in progress.')
    }

    Stop-TtxCurrentJob -Reason 'Stopped for cleanup.'
    Clear-TtxRunQueue -Reason 'Cleanup requested.'
    foreach ($item in @($script:Ttx.Queue)) {
        $st = Get-TtxStep -StepId $item.stepId
        if ($st.status -eq 'queued') { $st.status = $(if ($st.prereqs -and $st.prereqs.status -eq 'missing') { 'prereqs-missing' } else { 'pending' }) }
    }
    $script:Ttx.Queue.Clear()

    Add-TtxEvent -Message 'Cleanup started (executed steps in reverse order).'
    $steps = @($s.steps)
    [array]::Reverse($steps)
    $queued = 0
    foreach ($step in $steps) {
        if (-not $step.executed) {
            $step.cleanup = @{ status = 'skipped'; atUtc = (Get-TtxUtcNow); output = 'Never ran; nothing to clean up.'; remaining = @(); error = $null }
            continue
        }
        $step.status = 'cleanup-queued'
        $step.cleanup = @{ status = 'pending'; atUtc = $null; output = $null; remaining = @(); error = $null }
        [void]$script:Ttx.Queue.Add(@{ stepId = $step.id; op = 'cleanup' })
        $queued++
    }
    if ($queued -eq 0) { Complete-TtxCleanup }
    Save-TtxSession
    Write-TtxAnswerKey
    Start-TtxNextJob
    return (Get-TtxSessionView)
}

function Stop-TtxCurrentJob {
    param([string]$Reason)
    if (-not $script:Ttx.Job) { return }
    $step = Get-TtxStep -StepId $script:Ttx.JobItem.stepId
    $op = $script:Ttx.JobItem.op
    Stop-Job -Job $script:Ttx.Job
    Remove-Job -Job $script:Ttx.Job -Force
    $script:Ttx.Job = $null
    $script:Ttx.JobItem = $null
    $script:Ttx.JobStarted = $null
    $step.finishedAt = (Get-Date).ToString('o')
    if ($op -eq 'getprereqs') { $step.status = 'prereqs-missing' }
    else { $step.status = 'interrupted' }
    if ($op -eq 'cleanup' -and $step.cleanup) { $step.cleanup.status = 'interrupted' }
    if ($op -eq 'run' -and $step.run -and -not $step.run.endUtc) { $step.run.endUtc = Get-TtxUtcNow }
    Add-TtxEvent -StepId $step.id -Level warn -Message "Interrupted. $Reason"
}

# Runs CrowdStrike's benign test-detection trigger (D17) and records it in the
# session so the facilitator can mark whether it showed up in Falcon.
function Invoke-TtxCalibration {
    $s = $script:Ttx.Session
    if (-not $s -or $s.status -ne 'active') { throw (New-TtxConflict 'Load a scenario first; calibration is recorded in the session.') }
    try { $cal = Start-TtxFalconCalibration }
    catch { throw (New-TtxConflict "Could not start the calibration trigger: $($_.Exception.Message)") }
    $s.calibration = $cal
    Add-TtxEvent -Message "Calibration: started '$($cal.commandLine)' (PID $($cal.pid)). Check Falcon for a test detection in a few minutes, then mark the result."
    Save-TtxSession
    return (Get-TtxSessionView)
}

function Set-TtxCalibrationResult {
    param([string]$Result, [string]$Notes)
    $s = $script:Ttx.Session
    if (-not $s -or -not $s.calibration) { throw (New-TtxConflict 'Run the calibration check first.') }
    if ($Result -notin 'fired', 'not-fired', 'unknown') { throw (New-TtxBadRequest 'result must be fired, not-fired, or unknown.') }
    $s.calibration.result = $Result
    $s.calibration.notes = [string]$Notes
    Add-TtxEvent -Message "Calibration result marked: $Result."
    Save-TtxSession
    return (Get-TtxSessionView)
}

#endregion

#region Detection checklist and answer key

# Records which of a step's expected detections the facilitator actually saw in
# the EDR. Expected rows have ids 'exp-1', 'exp-2', ... (in the order the
# scenario lists them); the facilitator can also add ad-hoc rows ('custom:...').
function Set-TtxDetectionResult {
    param(
        [Parameter(Mandatory = $true)][string]$StepId,
        [Parameter(Mandatory = $true)][string]$DetectionId,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Notes
    )
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    $step = Get-TtxStep -StepId $StepId
    if (-not $step) { throw (New-TtxNotFound "Step '$StepId' not found.") }
    if ($Result -notin 'fired', 'not-fired', 'unknown') { throw (New-TtxBadRequest 'result must be fired, not-fired, or unknown.') }
    if ([string]::IsNullOrWhiteSpace($DetectionId)) { throw (New-TtxBadRequest 'detectionId is required.') }
    if ($DetectionId.Length -gt 200) { throw (New-TtxBadRequest 'detectionId is too long.') }

    if ($step.detections -isnot [hashtable]) { $step.detections = @{} }
    $step.detections[$DetectionId] = @{
        result   = $Result
        notes    = [string]$Notes
        markedAt = (Get-Date).ToString('o')
    }
    Add-TtxEvent -StepId $step.id -Message "Detection '$DetectionId' marked $Result."
    Save-TtxSession
    Write-TtxAnswerKey
    return (Get-TtxSessionView)
}

# Expected detections for a step, merged with whatever the facilitator recorded.
function Get-TtxStepDetectionRows {
    param([hashtable]$Step)
    $rows = @()
    $recorded = @{}
    if ($Step.detections -is [hashtable]) { $recorded = $Step.detections }
    $expectedIds = @()
    $i = 0
    foreach ($d in @($Step.expectedDetections)) {
        if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
        $i++
        $id = "exp-$i"
        $expectedIds += $id
        $mark = $recorded[$id]
        $rows += , @{
            id          = $id
            description = [string]$d
            expected    = $true
            result      = if ($mark) { [string]$mark.result } else { 'unknown' }
            notes       = if ($mark) { [string]$mark.notes } else { '' }
        }
    }
    # Stub modules may declare expected detections of their own.
    if ($Step.info -and $Step.info.expectedDetections) {
        foreach ($d in @($Step.info.expectedDetections)) {
            if ($null -eq $d) { continue }
            $id = [string]$d.id
            $expectedIds += $id
            $mark = $recorded[$id]
            $rows += , @{
                id          = $id
                description = "$([string]$d.description) ($("$($d.tactic) $($d.technique)".Trim()))"
                expected    = $true
                result      = if ($mark) { [string]$mark.result } else { 'unknown' }
                notes       = if ($mark) { [string]$mark.notes } else { '' }
            }
        }
    }
    # Ad-hoc rows the facilitator added that aren't in the expected list.
    foreach ($id in @($recorded.Keys | Sort-Object)) {
        if ($expectedIds -contains $id) { continue }
        $mark = $recorded[$id]
        $label = if ($id -like 'custom:*') { $id.Substring(7) } else { $id }
        $rows += , @{
            id          = $id
            description = "$label (added by facilitator)"
            expected    = $false
            result      = [string]$mark.result
            notes       = [string]$mark.notes
        }
    }
    return , $rows
}

# Fills {{Placeholder}} tokens in facilitator text with this run's values.
function Expand-TtxPlaceholders {
    param([string]$Text, [hashtable]$Values)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    foreach ($key in @($Values.Keys)) {
        $out = $out.Replace("{{$key}}", [string]$Values[$key])
    }
    return $out
}

# Values available to hunt notes and the answer key for this run.
function Get-TtxRunValues {
    $s = $script:Ttx.Session
    $pf = $s.preflight
    $values = @{
        Host      = [string]$pf.host
        User      = [string]$pf.user
        Aid       = if ($pf.aid) { [string]$pf.aid } else { '<AID unknown>' }
        SessionId = [string]$s.sessionId
    }
    foreach ($key in @($s.parameters.Keys)) { $values[$key] = [string]$s.parameters[$key] }
    return $values
}

# Hunt notes with {{Host}}, {{Aid}}, {{SessionId}} and {{<input argument>}}
# filled in.
function Get-TtxExpandedHuntNotes {
    param([hashtable]$Step)
    $v = Get-TtxRunValues
    if ($Step.values -is [hashtable]) { foreach ($k in @($Step.values.Keys)) { $v[$k] = [string]$Step.values[$k] } }
    return , @(foreach ($n in @($Step.huntNotes)) { Expand-TtxPlaceholders ([string]$n) $v })
}

# When telemetry from the last executed step should be visible in Falcon.
function Get-TtxReadyToHunt {
    $s = $script:Ttx.Session
    $last = $null
    foreach ($step in $s.steps) {
        $end = $null
        if ($step.run -and $step.run.endUtc) { $end = [string]$step.run.endUtc }
        elseif ($step.kind -eq 'module' -and $step.executed -and $step.finishedAt) { $end = [string]$step.finishedAt }
        if (-not $end) { continue }
        try { $t = [datetime]::Parse($end, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        catch { continue }
        if ($null -eq $last -or $t -gt $last) { $last = $t }
    }
    if ($null -eq $last) { return $null }
    return @{
        lastStepEndUtc = $last.ToString('o')
        readyAtUtc     = $last.AddMinutes($script:Ttx.TelemetryDelayMin).ToString('o')
        delayMinutes   = $script:Ttx.TelemetryDelayMin
    }
}

function Get-TtxMdCell {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '\|', '\|' -replace '\r?\n', ' ')
}

# Writes runs/<id>/answer-key.md from this run's recorded data.
function Write-TtxAnswerKey {
    $s = $script:Ttx.Session
    if (-not $s) { return }
    $v = Get-TtxRunValues
    $pf = $s.preflight
    $sb = New-Object System.Text.StringBuilder
    $fence = '```'

    [void]$sb.AppendLine("# Answer key - $($s.scenarioName)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Facilitator reference for this run, generated by TTX Control Center from the')
    [void]$sb.AppendLine('recorded run data. Commands are the installed Atomic Red Team tests after')
    [void]$sb.AppendLine('input-argument substitution. Detections are what the facilitator marked.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| | |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine("| Scenario | $(Get-TtxMdCell $s.scenarioName) (``$($s.scenarioId)``) |")
    [void]$sb.AppendLine("| Session | ``$($s.sessionId)`` ($($s.status)) |")
    [void]$sb.AppendLine("| Host | ``$($v.Host)`` |")
    [void]$sb.AppendLine("| User | ``$($v.User)`` (elevated: $($pf.elevated)) |")
    [void]$sb.AppendLine("| Falcon AID | ``$($v.Aid)`` |")
    [void]$sb.AppendLine("| Sensor | $($pf.falconService) |")
    if ($s.art) {
        $ver = if ($s.art.version) { $s.art.version } else { 'unknown' }
        [void]$sb.AppendLine("| Atomic Red Team | $ver at ``$($s.art.root)`` |")
    }
    if ($s.artifactRoot) { [void]$sb.AppendLine("| Stub artifact folder | ``$($s.artifactRoot)`` |") }
    $ready = Get-TtxReadyToHunt
    if ($ready) {
        [void]$sb.AppendLine("| Last step finished (UTC) | $($ready.lastStepEndUtc) |")
        [void]$sb.AppendLine("| Ready to hunt (estimate, UTC) | $($ready.readyAtUtc) |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> Telemetry may take a few minutes to appear in Falcon. The ready-to-hunt time assumes about $($script:Ttx.TelemetryDelayMin) minutes after the last step.")
    [void]$sb.AppendLine()
    if ($s.calibration) {
        [void]$sb.AppendLine("Calibration: ``$($s.calibration.commandLine)`` at $($s.calibration.ranAtUtc) -> result **$($s.calibration.result)**.")
        [void]$sb.AppendLine()
    }

    $i = 0
    foreach ($step in $s.steps) {
        $i++
        [void]$sb.AppendLine("## Step $i. $($step.title)")
        [void]$sb.AppendLine()
        $a = $step.atomic
        [void]$sb.AppendLine('| | |')
        [void]$sb.AppendLine('|---|---|')
        if ($step.tactic) { [void]$sb.AppendLine("| Tactic | $(Get-TtxMdCell $step.tactic) |") }
        if ($step.kind -eq 'module') {
            [void]$sb.AppendLine("| Step type | stub module ``$($step.module)`` (test only) |")
            if ($step.info -and $step.info.technique) { [void]$sb.AppendLine("| Technique | $($step.info.technique) |") }
        }
        elseif ($a) {
            [void]$sb.AppendLine("| Technique | $($a.techniqueId) - $(Get-TtxMdCell $a.techniqueName) |")
            [void]$sb.AppendLine("| ART test | #$($a.testNumber) $(Get-TtxMdCell $a.testName) |")
            [void]$sb.AppendLine("| GUID | ``$($a.guid)`` |")
            [void]$sb.AppendLine("| Executor | $($a.executor)$(if ($a.elevationRequired) { ' (elevation required)' }) |")
        }
        else {
            [void]$sb.AppendLine("| Technique | $($step.technique) |")
            [void]$sb.AppendLine("| GUID | ``$($step.atomicGuid)`` (not found in the installed atomics) |")
        }
        [void]$sb.AppendLine("| Status | **$($step.status)** |")
        if ($step.run -and $step.run.startUtc) {
            [void]$sb.AppendLine("| UTC window | $($step.run.startUtc) to $(if ($step.run.endUtc) { $step.run.endUtc } else { '(not finished)' }) |")
            $code = if ($null -ne $step.run.exitCode) { "$($step.run.exitCode) (from $($step.run.exitCodeSource))" } else { 'not reported' }
            [void]$sb.AppendLine("| Exit code | $code |")
        }
        elseif ($step.kind -eq 'module' -and $step.startedAt -and $step.executed) {
            [void]$sb.AppendLine("| Window (local) | $($step.startedAt) to $($step.finishedAt) |")
        }
        $cl = if ($step.cleanup) { [string]$step.cleanup.status } else { 'not run yet' }
        [void]$sb.AppendLine("| Cleanup | $cl |")
        [void]$sb.AppendLine()

        if ($a) {
            if ($a.description) {
                [void]$sb.AppendLine('**What the atomic does** (from its YAML):')
                [void]$sb.AppendLine()
                foreach ($line in ([string]$a.description -split '\r?\n')) { [void]$sb.AppendLine("> $line") }
                [void]$sb.AppendLine()
            }
            if ($step.values -is [hashtable] -and $step.values.Count -gt 0) {
                [void]$sb.AppendLine('Input arguments used:')
                foreach ($k in @($step.values.Keys | Sort-Object)) {
                    $over = if ($step.inputArguments -is [hashtable] -and $step.inputArguments.ContainsKey($k)) { ' (override)' } else { '' }
                    [void]$sb.AppendLine("- ``$k`` = ``$($step.values[$k])``$over")
                }
                [void]$sb.AppendLine()
            }
            $cmd = if ($step.run -and $step.run.command) { $step.run.command } else { $a.command }
            $label = if ($step.run -and $step.run.command) { 'Command that ran' } else { 'Command (not run yet)' }
            [void]$sb.AppendLine("**$label** ($($a.executor)):")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine($fence)
            [void]$sb.AppendLine(([string]$cmd).TrimEnd())
            [void]$sb.AppendLine($fence)
            [void]$sb.AppendLine()
            if ($step.prereqsFetched) {
                [void]$sb.AppendLine("Prerequisites were fetched with GetPrereqs (confirmed by the facilitator$(if ($step.getPrereqs -and $step.getPrereqs.confirmedAtUtc) { " at $($step.getPrereqs.confirmedAtUtc)" })). Their files are not removed by cleanup.")
                [void]$sb.AppendLine()
            }
        }
        if (@($step.artifacts).Count -gt 0) {
            [void]$sb.AppendLine('Artifacts reported by the stub module:')
            foreach ($art in @($step.artifacts)) { [void]$sb.AppendLine("- **$($art.type)** ``$($art.location)``$(if ($art.detail) { " - $($art.detail)" })") }
            [void]$sb.AppendLine()
        }

        $vr = @($step.verifyResults)
        if ($step.kind -eq 'module' -and $step.verify -is [hashtable]) {
            [void]$sb.AppendLine("Verify: $(if ($step.verify.passed) { 'pass' } else { 'fail' }) - $($step.verify.detail)")
            [void]$sb.AppendLine()
        }
        elseif ($vr.Count -gt 0) {
            [void]$sb.AppendLine('Verify results (after the run):')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('| Check | Target | Result | Detail |')
            [void]$sb.AppendLine('|---|---|---|---|')
            foreach ($r in $vr) { [void]$sb.AppendLine("| $($r.type) | $(Get-TtxMdCell $r.target) | $($r.result) | $(Get-TtxMdCell $r.detail) |") }
            [void]$sb.AppendLine()
        }
        elseif (@($step.verify).Count -gt 0) {
            [void]$sb.AppendLine("Verify checks defined: $(@($step.verify).Count) (not run yet).")
            [void]$sb.AppendLine()
        }

        $notes = Get-TtxExpandedHuntNotes -Step $step
        if (@($notes).Count -gt 0) {
            [void]$sb.AppendLine('Hunt notes:')
            foreach ($n in $notes) { [void]$sb.AppendLine("- $n") }
            [void]$sb.AppendLine()
        }
        if ($step.kind -eq 'module' -and $step.hunt) {
            foreach ($h in @($step.hunt.items)) { if ($h) { [void]$sb.AppendLine("- **$($h.title)** ($($h.where)): $($h.what)") } }
            if (@($step.hunt.items).Count -gt 0) { [void]$sb.AppendLine() }
        }

        $rows = Get-TtxStepDetectionRows -Step $step
        if (@($rows).Count -gt 0) {
            [void]$sb.AppendLine('Detections (expected vs. actual):')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('| Detection | Expected | Result | Notes |')
            [void]$sb.AppendLine('|---|---|---|---|')
            foreach ($r in $rows) {
                [void]$sb.AppendLine("| $(Get-TtxMdCell $r.description) | $(if ($r.expected) { 'yes' } else { 'no' }) | $($r.result) | $(Get-TtxMdCell $r.notes) |")
            }
            [void]$sb.AppendLine()
        }
    }

    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine("_Telemetry may take a few minutes to appear in Falcon. ART command lines and paths (AtomicRedTeam, Invoke-AtomicTest) may be visible to trainees in telemetry. Generated $((Get-Date).ToUniversalTime().ToString('o'))._")

    Write-TtxTextFile -Path (Join-Path (Get-TtxSessionDir) 'answer-key.md') -Text ($sb.ToString())
}

function Get-TtxAnswerKey {
    $s = $script:Ttx.Session
    if (-not $s) { throw (New-TtxConflict 'No scenario is loaded.') }
    $path = Join-Path (Get-TtxSessionDir) 'answer-key.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-TtxAnswerKey }
    return @{ path = $path; markdown = (Read-TtxTextFile -Path $path) }
}

# Called from the server loop: collects finished jobs, enforces timeouts, and
# starts the next queued operation.
function Update-TtxEngine {
    Update-TtxCatalogJob
    if ($script:Ttx.Job) {
        $state = $script:Ttx.Job.State
        if ($state -in 'Completed', 'Failed', 'Stopped') {
            Complete-TtxJob
        }
        elseif (((Get-Date) - $script:Ttx.JobStarted).TotalSeconds -gt $script:Ttx.JobTimeoutSec) {
            Complete-TtxJob -TimeoutMessage "Timed out after $($script:Ttx.JobTimeoutSec) seconds."
        }
    }
    Start-TtxNextJob
}

function Test-TtxCatalogBuilding { return ($null -ne $script:Ttx.CatalogJob) }

# Preflight for the configured ART root (GET /api/preflight).
function Get-TtxHostPreflight { return (Get-TtxPreflight -ArtRoot $script:Ttx.ArtRoot) }

# Called when the server shuts down.
function Stop-TtxEngine {
    if ($script:Ttx.CatalogJob) {
        Stop-Job -Job $script:Ttx.CatalogJob
        Remove-Job -Job $script:Ttx.CatalogJob -Force
        $script:Ttx.CatalogJob = $null
    }
    if ($script:Ttx.Session -and (Test-TtxBusy)) {
        Stop-TtxCurrentJob -Reason 'Server is shutting down.'
        foreach ($item in @($script:Ttx.Queue)) {
            $step = Get-TtxStep -StepId $item.stepId
            if ($step.status -eq 'queued') { $step.status = 'pending' }
            elseif ($step.status -eq 'cleanup-queued') { $step.status = 'interrupted'; if ($step.cleanup) { $step.cleanup.status = 'interrupted' } }
        }
        $script:Ttx.Queue.Clear()
        Save-TtxSession
    }
}

#endregion

Export-ModuleMember -Function Initialize-TtxEngine, Get-TtxScenarioList, Get-TtxScenario, Save-TtxScenario,
    New-TtxSession, Get-TtxSessionView,
    Start-TtxStep, Start-TtxRunAll, Start-TtxGetPrereqs, Start-TtxCleanup, Update-TtxEngine, Stop-TtxEngine,
    Get-TtxPreflight, Invoke-TtxCalibration, Set-TtxCalibrationResult,
    Set-TtxDetectionResult, Get-TtxAnswerKey,
    Get-TtxCatalogStatus, Get-TtxCatalogJson, Get-TtxCatalogTest, Get-TtxAtomicPreview, Start-TtxCatalogBuild,
    Test-TtxCatalogBuilding, Get-TtxHostPreflight,
    ConvertFrom-TtxJson, ConvertTo-TtxJson
