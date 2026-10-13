# Host and EDR sensor preflight. Windows PowerShell 5.1.
# Dot-sourced by Engine.psm1. Nothing here blocks an exercise: it only reports.

# The CrowdStrike Falcon sensor's agent ID (AID) is stored as binary value 'AG'
# under this key. Confirm against your CrowdStrike documentation (D17).
$script:FalconAidKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\CSAgent\Sim'

function Test-TtxIsElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal $identity
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-TtxFalconAid {
    try {
        $value = (Get-ItemProperty -LiteralPath $script:FalconAidKey -Name 'AG' -ErrorAction Stop).AG
        if ($value -is [byte[]]) {
            return (($value | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-TtxPreflight {
    $warnings = @()
    $serviceStatus = 'not found'
    if (Get-Command -Name Get-Service -ErrorAction SilentlyContinue) {
        $svc = Get-Service -Name 'CSFalconService' -ErrorAction SilentlyContinue
        if ($svc) { $serviceStatus = [string]$svc.Status }
    }
    else {
        $serviceStatus = 'unavailable (not Windows)'
    }
    $running = ($serviceStatus -eq 'Running')
    if (-not $running) {
        $warnings += "CrowdStrike Falcon sensor (CSFalconService) is not running (status: $serviceStatus). Steps will still run, but nothing will reach Falcon."
    }
    $aid = Get-TtxFalconAid
    if ($running -and -not $aid) {
        $warnings += 'Could not read the Falcon AID from the registry (try an elevated console). Queries will need the AID filled in by hand.'
    }
    $elevated = Test-TtxIsElevated
    return @{
        host          = [string]$env:COMPUTERNAME
        user          = "$env:USERDOMAIN\$env:USERNAME"
        elevated      = $elevated
        checkedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        falconService = $serviceStatus
        sensorRunning = $running
        aid           = $aid
        warnings      = $warnings
    }
}

# Starts CrowdStrike's documented benign test-detection trigger. '/t 5 /d Y'
# makes choice.exe answer itself after 5 seconds so it can never wait for
# input. Returns immediately with the process details.
function Start-TtxFalconCalibration {
    $arguments = '/m crowdstrike_sample_detection /t 5 /d Y'
    $proc = Start-Process -FilePath 'choice.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    return @{
        ranAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        commandLine = "choice.exe $arguments"
        pid         = $proc.Id
        result      = 'unknown'
        notes       = ''
    }
}
