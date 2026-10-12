<#
.SYNOPSIS
    Starts TTX Control Center on http://localhost:<Port>/.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1

.EXAMPLE
    .\Start-ControlCenter.ps1 -Port 8090 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$NoBrowser,
    [int]$StepTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "TTX Control Center needs Windows PowerShell 5.1 or later (found $($PSVersionTable.PSVersion))."
}

$serverDir = Join-Path $PSScriptRoot 'server'
Import-Module (Join-Path $serverDir 'Engine.psm1') -Force
Import-Module (Join-Path $serverDir 'Server.psm1') -Force

Initialize-TtxEngine -Root $PSScriptRoot -StepTimeoutSec $StepTimeoutSeconds
Start-TtxServer -Port $Port -UiRoot (Join-Path $PSScriptRoot 'ui') -OpenBrowser:(-not $NoBrowser)
