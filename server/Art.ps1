# Atomic Red Team (ART) integration helpers. Windows PowerShell 5.1.
# Dot-sourced by the engine, the catalog builder and the ART step runner.
#
# This repo contains orchestration only (decision D19): nothing here defines
# attack behavior. Commands come from the atomics installed on the host; the
# helpers below locate ART, describe what a test would run (string
# substitution only, never execution) and apply the guardrails.

$script:TtxDefaultArtRoot = 'C:\AtomicRedTeam'

# Destructive / high-impact techniques. Tests in these (or their
# sub-techniques) need a typed confirmation to be added to a scenario.
$script:TtxHighImpactTechniques = @('T1485', 'T1486', 'T1489', 'T1490', 'T1529', 'T1561')

# A get_prereq_command matching this probably downloads something.
$script:TtxDownloadPattern = '(?i)(https?://|Invoke-WebRequest|\biwr\b|\bwget\b|\bcurl\b|DownloadFile|DownloadString|DownloadData|Start-BitsTransfer|bitsadmin|-urlcache|Install-Module|Install-Package|Invoke-FetchFromZip|Invoke-WebRequestVerifyHash|\bgit\s+clone\b|\bpip\s+install\b|choco\s+install|winget\s+install)'

# Where ART lives: explicit value > TTX_ART_ROOT environment variable > default.
function Resolve-TtxArtRoot {
    param([string]$ArtRoot)
    if (-not [string]::IsNullOrWhiteSpace($ArtRoot)) { return $ArtRoot.TrimEnd('\', '/') }
    if (-not [string]::IsNullOrWhiteSpace($env:TTX_ART_ROOT)) { return $env:TTX_ART_ROOT.TrimEnd('\', '/') }
    return $script:TtxDefaultArtRoot
}

function Get-TtxArtPaths {
    param([Parameter(Mandatory = $true)][string]$ArtRoot)
    return @{
        root        = $ArtRoot
        modulePath  = Join-Path (Join-Path $ArtRoot 'invoke-atomicredteam') 'Invoke-AtomicRedTeam.psd1'
        atomicsPath = Join-Path $ArtRoot 'atomics'
    }
}

# Imports the ART module by path (it may not be on $PSModulePath). Returns the
# PSModuleInfo. Throws with a readable message if it can't be imported.
# Call it dot-sourced at script level ($m = . Import-TtxArtModule ...): ART
# defines its classes (AtomicTechnique, ...) in a ScriptsToProcess script that
# runs in the caller's scope, and Get-AtomicTechnique fails if those classes
# are only visible inside this function.
function Import-TtxArtModule {
    param([Parameter(Mandatory = $true)][string]$ModulePath)
    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        throw "ART module not found at $ModulePath. Install Invoke-AtomicRedTeam there or set the ART root."
    }
    try {
        $mod = Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'powershell-yaml') { $msg = "$msg (install it with: Install-Module powershell-yaml -Scope CurrentUser)" }
        throw "Could not import the ART module from $ModulePath : $msg"
    }
    # -PassThru also returns ART's nested logger modules; pick the main one.
    $main = @($mod | Where-Object { $_.Name -eq 'Invoke-AtomicRedTeam' }) | Select-Object -First 1
    if (-not $main) { $main = $mod | Select-Object -First 1 }
    return $main
}

function Test-TtxHighImpactTechnique {
    param([string]$TechniqueId)
    if ([string]::IsNullOrWhiteSpace($TechniqueId)) { return $false }
    $base = $TechniqueId.Trim().ToUpperInvariant().Split('.')[0]
    return ($script:TtxHighImpactTechniques -contains $base)
}

function Test-TtxDownloadCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -match $script:TtxDownloadPattern)
}

# Input-argument values a test will use: the step's override where the atomic
# defines that argument, otherwise the atomic's default (same rule as ART's
# Get-InputArgs). Overrides for arguments the atomic doesn't define are
# ignored, as ART ignores them.
function Get-TtxResolvedInputArgs {
    param($Definitions, [hashtable]$Overrides)
    $values = @{}
    foreach ($d in @($Definitions)) {
        if ($null -eq $d) { continue }
        $values[[string]$d.name] = [string]$d.default
    }
    if ($Overrides) {
        foreach ($k in @($Overrides.Keys)) {
            if ($values.ContainsKey([string]$k)) { $values[[string]$k] = [string]$Overrides[$k] }
        }
    }
    return $values
}

# The command text ART will run: '#{arg}' replaced with the resolved value and
# PathToAtomicsFolder replaced with the atomics path (as ART's Merge-InputArgs
# does). String substitution only; nothing is executed.
function Expand-TtxAtomicCommand {
    param([string]$Command, [hashtable]$Values, [string]$AtomicsPath)
    if ($null -eq $Command) { return $null }
    $out = [string]$Command
    if ($Values) {
        foreach ($k in @($Values.Keys)) { $out = $out.Replace('#{' + $k + '}', [string]$Values[$k]) }
    }
    if ($AtomicsPath) {
        $out = $out.Replace('$PathToAtomicsFolder', $AtomicsPath).Replace('PathToAtomicsFolder', $AtomicsPath)
    }
    return $out
}

# A quick fingerprint of the installed atomics, used to tell whether the
# cached catalog is still current: number of technique YAML files, their
# total size and newest write time.
function Get-TtxAtomicsFingerprint {
    param([Parameter(Mandatory = $true)][string]$AtomicsPath)
    if (-not (Test-Path -LiteralPath $AtomicsPath -PathType Container)) { return $null }
    $count = 0
    $size = [long]0
    $newest = [long]0
    foreach ($dir in @(Get-ChildItem -LiteralPath $AtomicsPath -Directory -Filter 'T*')) {
        $yaml = Join-Path $dir.FullName ($dir.Name + '.yaml')
        if (-not (Test-Path -LiteralPath $yaml -PathType Leaf)) { continue }
        $f = Get-Item -LiteralPath $yaml
        $count++
        $size += $f.Length
        if ($f.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $f.LastWriteTimeUtc.Ticks }
    }
    return "$count|$size|$newest"
}

# ART status for preflight. Imports the module in a fresh runspace so the
# caller's session is untouched and a broken install can't take it down.
function Get-TtxArtStatus {
    param([Parameter(Mandatory = $true)][string]$ArtRoot)
    $paths = Get-TtxArtPaths -ArtRoot $ArtRoot
    $status = @{
        root              = $ArtRoot
        rootFound         = (Test-Path -LiteralPath $ArtRoot -PathType Container)
        modulePath        = $paths.modulePath
        moduleFound       = (Test-Path -LiteralPath $paths.modulePath -PathType Leaf)
        moduleImportable  = $false
        moduleVersion     = $null
        moduleError       = $null
        hasGetAtomicTechnique = $false
        atomicsPath       = $paths.atomicsPath
        atomicsFound      = (Test-Path -LiteralPath $paths.atomicsPath -PathType Container)
        techniqueCount    = 0
        yamlAvailable     = $false
        yamlVersion       = $null
        warnings          = @()
    }

    $yaml = Get-Module -ListAvailable -Name 'powershell-yaml' | Sort-Object Version -Descending | Select-Object -First 1
    if ($yaml) {
        $status.yamlAvailable = $true
        $status.yamlVersion = [string]$yaml.Version
    }

    if ($status.moduleFound) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        try {
            [void]$ps.AddScript({
                    param($ModulePath)
                    $all = @(Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue)
                    $m = @($all | Where-Object { $_.Name -eq 'Invoke-AtomicRedTeam' }) | Select-Object -First 1
                    if (-not $m) { $m = $all | Select-Object -First 1 }
                    @{
                        version = [string]$m.Version
                        hasGet  = [bool](Get-Command -Name 'Get-AtomicTechnique' -Module $m.Name -ErrorAction SilentlyContinue)
                        hasInvoke = [bool](Get-Command -Name 'Invoke-AtomicTest' -Module $m.Name -ErrorAction SilentlyContinue)
                    }
                }).AddArgument($paths.modulePath)
            $out = @($ps.Invoke()) | Select-Object -Last 1
            if ($ps.HadErrors -or $null -eq $out) {
                $err = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
                if (-not $err) { $err = 'Import produced no module.' }
                $status.moduleError = $err
            }
            elseif (-not $out.hasInvoke) {
                $status.moduleError = 'The module imported but does not export Invoke-AtomicTest.'
                $status.moduleVersion = $out.version
            }
            else {
                $status.moduleImportable = $true
                $status.moduleVersion = $out.version
                $status.hasGetAtomicTechnique = $out.hasGet
            }
        }
        catch {
            $status.moduleError = $_.Exception.Message
        }
        finally {
            $ps.Dispose()
        }
    }

    if ($status.atomicsFound) {
        $status.techniqueCount = @(Get-ChildItem -LiteralPath $paths.atomicsPath -Directory -Filter 'T*').Count
    }

    if (-not $status.rootFound) {
        $status.warnings += "Atomic Red Team was not found at $ArtRoot. ART steps can't run. Install it there or start the control center with -ArtRoot <path>."
    }
    else {
        if (-not $status.moduleFound) { $status.warnings += "ART module not found at $($paths.modulePath)." }
        elseif (-not $status.moduleImportable) { $status.warnings += "ART module could not be imported: $($status.moduleError)" }
        if (-not $status.atomicsFound) { $status.warnings += "Atomics folder not found at $($paths.atomicsPath). The catalog will be empty." }
    }
    if (-not $status.yamlAvailable) {
        $status.warnings += 'The powershell-yaml module is not installed. ART needs it (Install-Module powershell-yaml -Scope CurrentUser).'
    }
    return $status
}
