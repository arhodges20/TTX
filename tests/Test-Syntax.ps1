<#
.SYNOPSIS
    Static checks: every .ps1/.psm1 parses, every scenario.json is valid JSON,
    and every module defines the five contract functions. Exit code 0 = pass.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } |
        Where-Object { $_.FullName -notmatch '[\\/](runs|\.git)[\\/]' }) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failures++
        foreach ($e in $errors) { Write-Host "FAIL parse $($file.FullName):$($e.Extent.StartLineNumber) $($e.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "ok   parse $($file.FullName.Substring($root.Length + 1))"
    }
}

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'scenarios') -Recurse -File -Filter scenario.json) {
    try {
        $null = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        Write-Host "ok   json  $($file.FullName.Substring($root.Length + 1))"
    }
    catch {
        $failures++
        Write-Host "FAIL json  $($file.FullName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

$required = 'Get-TtxModuleInfo', 'Invoke-TtxRun', 'Test-TtxVerify', 'Invoke-TtxCleanup', 'Get-TtxHunt'
foreach ($dir in Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Directory | Where-Object { $_.Name -notlike '_*' }) {
    $path = Join-Path $dir.FullName 'module.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        $failures++
        Write-Host "FAIL module $($dir.Name): module.ps1 missing" -ForegroundColor Red
        continue
    }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
    $missing = @($required | Where-Object { $defined -notcontains $_ })
    if ($missing.Count -gt 0) {
        $failures++
        Write-Host "FAIL module $($dir.Name): missing $($missing -join ', ')" -ForegroundColor Red
    }
    else {
        Write-Host "ok   module $($dir.Name)"
    }
}

if ($failures -gt 0) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All syntax checks passed.' -ForegroundColor Green
exit 0
