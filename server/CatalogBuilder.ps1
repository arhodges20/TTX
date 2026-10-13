<#
.SYNOPSIS
    Builds the browsable ART catalog from the installed atomics.

.DESCRIPTION
    The engine runs this in a background job (a separate powershell.exe), so
    parsing a few hundred YAML files never blocks the UI. It reads each
    <atomics>\T*\T*.yaml with the ART module's own Get-AtomicTechnique when the
    module exports it, otherwise with ConvertFrom-Yaml from powershell-yaml,
    keeps the tests that support Windows, and writes the catalog as JSON to
    OutPath. Prints one JSON summary line: { ok, error, count, parser, ... }.
    Nothing here runs a test.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtRoot,
    [Parameter(Mandatory = $true)][string]$OutPath,
    [ValidateSet('auto', 'module', 'yaml')][string]$Parser = 'auto'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TtxCommon.ps1')
. (Join-Path $PSScriptRoot 'Art.ps1')

# Reads a member from either a hashtable (powershell-yaml) or an object (ART's
# AtomicTechnique classes).
function Get-TtxMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-TtxCatalogTest {
    param($Technique, $Test, [int]$Number, [string]$YamlPath)
    $techId = [string](@(Get-TtxMember $Technique 'attack_technique') | Select-Object -First 1)
    $executor = Get-TtxMember $Test 'executor'
    $inputs = @()
    $ia = Get-TtxMember $Test 'input_arguments'
    if ($ia -is [System.Collections.IDictionary]) {
        foreach ($name in @($ia.Keys | Sort-Object)) {
            $def = $ia[$name]
            $inputs += , @{
                name        = [string]$name
                description = ([string](Get-TtxMember $def 'description')).Trim()
                type        = [string](Get-TtxMember $def 'type')
                default     = [string](Get-TtxMember $def 'default')
            }
        }
    }
    $deps = @()
    foreach ($d in @(Get-TtxMember $Test 'dependencies')) {
        if ($null -eq $d) { continue }
        $get = [string](Get-TtxMember $d 'get_prereq_command')
        $deps += , @{
            description      = ([string](Get-TtxMember $d 'description')).Trim()
            prereqCommand    = [string](Get-TtxMember $d 'prereq_command')
            getPrereqCommand = $get
            downloads        = (Test-TtxDownloadCommand $get)
        }
    }
    $platforms = @(@(Get-TtxMember $Test 'supported_platforms') | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    return @{
        techniqueId        = $techId
        techniqueName      = [string](Get-TtxMember $Technique 'display_name')
        testNumber         = $Number
        testName           = [string](Get-TtxMember $Test 'name')
        guid               = ([string](Get-TtxMember $Test 'auto_generated_guid')).ToLowerInvariant()
        description        = ([string](Get-TtxMember $Test 'description')).Trim()
        platforms          = $platforms
        executor           = [string](Get-TtxMember $executor 'name')
        elevationRequired  = [bool](Get-TtxMember $executor 'elevation_required')
        command            = [string](Get-TtxMember $executor 'command')
        cleanupCommand     = [string](Get-TtxMember $executor 'cleanup_command')
        inputArguments     = $inputs
        hasDependencies    = ($deps.Count -gt 0)
        dependencyExecutor = [string](Get-TtxMember $Test 'dependency_executor_name')
        dependencies       = $deps
        prereqDownloads    = (@($deps | Where-Object { $_.downloads }).Count -gt 0)
        highImpact         = (Test-TtxHighImpactTechnique $techId)
        yamlPath           = $YamlPath
    }
}

$summary = @{ ok = $false; error = $null; count = 0; parser = $null; artVersion = $null; errors = @() }
try {
    $paths = Get-TtxArtPaths -ArtRoot $ArtRoot
    if (-not (Test-Path -LiteralPath $paths.atomicsPath -PathType Container)) {
        throw "Atomics folder not found at $($paths.atomicsPath)."
    }

    $useModule = $false
    $moduleError = $null
    if ($Parser -in 'auto', 'module') {
        try {
            $mod = . Import-TtxArtModule -ModulePath $paths.modulePath
            $summary.artVersion = [string]$mod.Version
            if (Get-Command -Name 'Get-AtomicTechnique' -Module $mod.Name -ErrorAction SilentlyContinue) { $useModule = $true }
            else { $moduleError = 'the ART module does not export Get-AtomicTechnique' }
        }
        catch { $moduleError = $_.Exception.Message }
        if ($Parser -eq 'module' -and -not $useModule) { throw "Can't parse with the ART module: $moduleError" }
    }
    if ($useModule) {
        $summary.parser = 'Get-AtomicTechnique'
    }
    else {
        try { Import-Module -Name 'powershell-yaml' -ErrorAction Stop }
        catch {
            $why = if ($moduleError) { " ($moduleError)" } else { '' }
            throw "Can't read the atomics: the ART module's Get-AtomicTechnique isn't available$why and powershell-yaml isn't installed (Install-Module powershell-yaml -Scope CurrentUser)."
        }
        $summary.parser = 'powershell-yaml'
    }

    $tests = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $techniques = 0
    $skippedPlatform = 0
    $skippedManual = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $paths.atomicsPath -Directory -Filter 'T*' | Sort-Object Name)) {
        $yaml = Join-Path $dir.FullName ($dir.Name + '.yaml')
        if (-not (Test-Path -LiteralPath $yaml -PathType Leaf)) { continue }
        try {
            if ($useModule) { $tech = Get-AtomicTechnique -Path $yaml | Select-Object -First 1 }
            else { $tech = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($yaml)) }
            $techniques++
            $n = 0
            foreach ($t in @(Get-TtxMember $tech 'atomic_tests')) {
                if ($null -eq $t) { continue }
                $n++
                $rec = ConvertTo-TtxCatalogTest -Technique $tech -Test $t -Number $n -YamlPath $yaml
                if ($rec.platforms -notcontains 'windows') { $skippedPlatform++; continue }
                # ART can't run manual tests, so they aren't offered.
                if ($rec.executor -eq 'manual' -or [string]::IsNullOrWhiteSpace($rec.command)) { $skippedManual++; continue }
                if ([string]::IsNullOrWhiteSpace($rec.guid)) {
                    [void]$errors.Add("$($dir.Name) test $n has no auto_generated_guid; skipped.")
                    continue
                }
                [void]$tests.Add($rec)
            }
        }
        catch {
            [void]$errors.Add("$($dir.Name): $($_.Exception.Message)")
        }
    }

    $catalog = @{
        schemaVersion   = 1
        builtAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        artRoot         = $ArtRoot
        atomicsPath     = $paths.atomicsPath
        fingerprint     = (Get-TtxAtomicsFingerprint -AtomicsPath $paths.atomicsPath)
        parser          = $summary.parser
        artVersion      = $summary.artVersion
        techniqueCount  = $techniques
        skippedPlatform = $skippedPlatform
        skippedManual   = $skippedManual
        errors          = @($errors)
        tests           = @($tests)
    }
    $dirOut = Split-Path -Parent $OutPath
    if ($dirOut -and -not (Test-Path -LiteralPath $dirOut)) { New-Item -ItemType Directory -Path $dirOut -Force | Out-Null }
    Write-TtxTextFile -Path $OutPath -Text (ConvertTo-TtxJson -InputObject $catalog -Compress)
    $summary.ok = $true
    $summary.count = $tests.Count
    $summary.errors = @($errors)
}
catch {
    $summary.error = $_.Exception.Message
}

ConvertTo-Json -InputObject $summary -Depth 4 -Compress
