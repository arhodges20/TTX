# Host, EDR / telemetry agents (CrowdStrike Falcon, Elastic Agent, Elastic
# Defend, Sysmon) and Atomic Red Team preflight. Windows PowerShell 5.1.
# Dot-sourced by Engine.psm1 (after Art.ps1). Nothing here blocks an exercise:
# it only reports. (ART steps themselves refuse to run without ART.)

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

# EDR and telemetry agents the preflight looks for. Each is found by its
# Windows service; the first service name that exists wins.
$script:TtxAgents = @(
    @{ id = 'falcon'; name = 'CrowdStrike Falcon'; kind = 'edr'; services = @('CSFalconService') },
    @{ id = 'elastic-agent'; name = 'Elastic Agent'; kind = 'edr'; services = @('Elastic Agent', 'elastic-agent') },
    @{ id = 'elastic-defend'; name = 'Elastic Defend'; kind = 'edr'; services = @('ElasticEndpoint') },
    @{ id = 'sysmon'; name = 'Sysmon'; kind = 'telemetry'; services = @('Sysmon64', 'Sysmon') }
)
$script:TtxElasticAgentExe = 'C:\Program Files\Elastic\Agent\elastic-agent.exe'

# Parses `elastic-agent status --output json`. 8.x puts id/version under
# "info"; older builds put "id" at the top level.
function ConvertFrom-TtxElasticStatus {
    param([string]$Json)
    $r = @{ id = $null; version = $null; state = $null }
    if ([string]::IsNullOrWhiteSpace($Json)) { return $r }
    try { $j = ConvertFrom-Json -InputObject $Json } catch { return $r }
    if ($j.info) {
        $r.id = [string]$j.info.id
        $r.version = [string]$j.info.version
    }
    if (-not $r.id -and $j.id) { $r.id = [string]$j.id }
    if ($j.message) { $r.state = [string]$j.message }
    elseif ($j.status) { $r.state = [string]$j.status }
    if (-not $r.id) { $r.id = $null }
    if (-not $r.version) { $r.version = $null }
    return $r
}

# Asks the local Elastic Agent for its ID and version (needs an elevated
# console). Waits at most 5 s; returns empty values if anything fails.
$script:TtxElasticInfoCache = $null

function Get-TtxElasticAgentInfo {
    # Cached for 5 minutes: the call takes a few seconds and runs on the
    # server's only thread.
    $c = $script:TtxElasticInfoCache
    if ($c -and ((Get-Date) - $c.at).TotalSeconds -lt 300) { return $c.info }
    $info = Get-TtxElasticAgentInfoUncached
    $script:TtxElasticInfoCache = @{ at = (Get-Date); info = $info }
    return $info
}

function Get-TtxElasticAgentInfoUncached {
    $empty = @{ id = $null; version = $null; state = $null }
    if (-not (Test-Path -LiteralPath $script:TtxElasticAgentExe -PathType Leaf)) { return $empty }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:TtxElasticAgentExe
        $psi.Arguments = 'status --output json'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch { Write-Verbose 'elastic-agent status did not exit' }; return $empty }
        $info = ConvertFrom-TtxElasticStatus -Json $out.Result
        if (-not $info.version) {
            $info.version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:TtxElasticAgentExe).ProductVersion
        }
        return $info
    }
    catch {
        return $empty
    }
}

# Status of each known agent: present (service exists), running, and the
# agent ID where one can be read.
function Get-TtxAgentStatus {
    $hasServices = [bool](Get-Command -Name Get-Service -ErrorAction SilentlyContinue)
    $list = @()
    foreach ($a in $script:TtxAgents) {
        $item = @{ id = $a.id; name = $a.name; kind = $a.kind; service = $null; status = 'not found'; present = $false; running = $false; agentId = $null; idLabel = $null; version = $null }
        if (-not $hasServices) { $item.status = 'unavailable (not Windows)'; $list += , $item; continue }
        foreach ($n in $a.services) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc) { $item.service = $n; $item.status = [string]$svc.Status; $item.present = $true; break }
        }
        $item.running = ($item.status -eq 'Running')
        if ($a.id -eq 'falcon' -and $item.present) {
            $item.idLabel = 'AID'
            $item.agentId = Get-TtxFalconAid
        }
        if ($a.id -eq 'elastic-agent' -and $item.running) {
            $info = Get-TtxElasticAgentInfo
            $item.idLabel = 'Agent ID'
            $item.agentId = $info.id
            $item.version = $info.version
        }
        $list += , $item
    }
    return , $list
}

function Get-TtxPreflight {
    param([string]$ArtRoot)
    $warnings = @()
    $agents = Get-TtxAgentStatus
    $falcon = @($agents | Where-Object { $_.id -eq 'falcon' })[0]
    $runningEdr = @($agents | Where-Object { $_.kind -eq 'edr' -and $_.running })
    $runningAny = @($agents | Where-Object { $_.running })

    foreach ($a in $agents) {
        if ($a.present -and -not $a.running) {
            $warnings += "$($a.name) is installed but not running (service $($a.service): $($a.status)). Its telemetry won't be collected."
        }
    }
    if ($runningEdr.Count -eq 0) {
        $local = if ($runningAny.Count -gt 0) { " Only $(($runningAny | ForEach-Object { $_.name }) -join ', ') is logging, locally." } else { '' }
        $warnings += "No EDR agent is running (looked for CrowdStrike Falcon, Elastic Agent and Elastic Defend). Steps will still run, but nothing will reach an EDR console.$local"
    }
    if ($falcon.running -and -not $falcon.agentId) {
        $warnings += 'Could not read the Falcon AID from the registry (try an elevated console). Queries will need the AID filled in by hand.'
    }
    $elastic = @($agents | Where-Object { $_.id -eq 'elastic-agent' })[0]
    if ($elastic.running -and -not $elastic.agentId) {
        $warnings += 'Could not read the Elastic Agent ID (run the control center from an elevated console). Search by host name instead.'
    }

    $elevated = Test-TtxIsElevated
    $art = Get-TtxArtStatus -ArtRoot (Resolve-TtxArtRoot $ArtRoot)
    $warnings += @($art.warnings)
    return @{
        host          = $(if ($env:COMPUTERNAME) { [string]$env:COMPUTERNAME } else { [Environment]::MachineName })
        user          = $(if ($env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { [Environment]::UserName })
        elevated      = $elevated
        checkedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        agents        = $agents
        # Names of the EDRs that are running, for labels ("Detections in ...").
        edrNames      = @($runningEdr | ForEach-Object { $_.name })
        # Falcon fields kept for older sessions and the calibration check.
        falconService = $falcon.status
        sensorRunning = [bool]$falcon.running
        aid           = $falcon.agentId
        elasticAgentId = $elastic.agentId
        art           = $art
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
