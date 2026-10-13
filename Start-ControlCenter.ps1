<#
.SYNOPSIS
    Starts TTX Control Center on http://localhost:<Port>/.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Start-ControlCenter.ps1

.EXAMPLE
    .\Start-ControlCenter.ps1 -Port 8090 -NoBrowser

.EXAMPLE
    .\Start-ControlCenter.ps1 -ArtRoot D:\Tools\AtomicRedTeam

.PARAMETER ArtRoot
    Atomic Red Team install folder (contains invoke-atomicredteam\ and
    atomics\). Default: $env:TTX_ART_ROOT if set, else C:\AtomicRedTeam.

.PARAMETER TelemetryDelayMinutes
    Minutes to allow for telemetry to reach Falcon when estimating when the
    trainees can start hunting. Default 5.
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$NoBrowser,
    [int]$StepTimeoutSeconds = 120,
    [string]$ArtRoot,
    [int]$TelemetryDelayMinutes = 5
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "TTX Control Center needs Windows PowerShell 5.1 or later (found $($PSVersionTable.PSVersion))."
}

$serverDir = Join-Path $PSScriptRoot 'server'
Import-Module (Join-Path $serverDir 'Engine.psm1') -Force
Import-Module (Join-Path $serverDir 'Server.psm1') -Force

Initialize-TtxEngine -Root $PSScriptRoot -StepTimeoutSec $StepTimeoutSeconds -ArtRoot $ArtRoot -TelemetryDelayMinutes $TelemetryDelayMinutes
Start-TtxServer -Port $Port -UiRoot (Join-Path $PSScriptRoot 'ui') -OpenBrowser:(-not $NoBrowser)
