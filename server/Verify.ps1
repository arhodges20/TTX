# Declarative, read-only verify checks for scenario steps. Windows PowerShell 5.1.
# Dot-sourced by the engine (to validate scenarios) and by the ART step runner
# (to run them). These checks only look; none of them changes the host.
#
# They supplement ART's exit status: a check confirms the step actually left
# the artifact the facilitator expects. Each result is pass, fail or unknown
# (the check couldn't tell, e.g. the cmdlet or log isn't available here).

# type -> required fields (other fields are optional).
$script:TtxVerifyTypes = [ordered]@{
    file_exists                  = @('path')
    scheduled_task_exists        = @('name')
    registry_value_exists        = @('key')
    service_exists               = @('name')
    process_ran_since_step_start = @('name')
}

# Returns a list of problems with one check definition (empty = valid).
function Test-TtxVerifyDefinition {
    param($Check)
    $problems = @()
    if ($Check -isnot [System.Collections.IDictionary]) { return , @('each verify entry must be an object') }
    $type = [string]$Check['type']
    if (-not $script:TtxVerifyTypes.Contains($type)) {
        return , @("unknown verify type '$type' (use one of: $(@($script:TtxVerifyTypes.Keys) -join ', '))")
    }
    foreach ($field in $script:TtxVerifyTypes[$type]) {
        if ([string]::IsNullOrWhiteSpace([string]$Check[$field])) { $problems += "$type needs '$field'" }
    }
    return , $problems
}

# Fills '#{arg}' with the step's input-argument values and expands %VAR% and
# $env:VAR, so a check can name the same path the atomic used.
function Expand-TtxVerifyText {
    param([string]$Text, [hashtable]$Values)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    if ($Values) {
        foreach ($k in @($Values.Keys)) { $out = $out.Replace('#{' + $k + '}', [string]$Values[$k]) }
    }
    $out = [regex]::Replace($out, '\$env:([A-Za-z_][A-Za-z0-9_]*)', {
            param($m)
            $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
            if ($null -eq $v) { return $m.Value }
            return $v
        })
    return [Environment]::ExpandEnvironmentVariables($out)
}

function ConvertTo-TtxRegistryPath {
    param([string]$Key)
    $k = $Key.Trim()
    $map = @{
        'HKCU' = 'HKEY_CURRENT_USER'; 'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKU' = 'HKEY_USERS'
        'HKCR' = 'HKEY_CLASSES_ROOT'; 'HKCC' = 'HKEY_CURRENT_CONFIG'
    }
    if ($k -match '^Registry::') { return $k }
    if ($k -match '^(HKCU|HKLM|HKU|HKCR|HKCC):?\\(.*)$') { return "Registry::$($map[$Matches[1].ToUpperInvariant()])\$($Matches[2])" }
    if ($k -match '^(HKEY_[A-Z_]+)\\(.*)$') { return "Registry::$($Matches[1].ToUpperInvariant())\$($Matches[2])" }
    return $null
}

function Test-TtxProcessInLog {
    param([string]$LogName, [int]$EventId, [datetime]$Since, [string]$ImageName, [string]$Field)
    # Returns $true/$false if the log could answer, $null if it couldn't.
    if (-not (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) { return $null }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; Id = $EventId; StartTime = $Since } -ErrorAction Stop)
    }
    catch {
        # "No events were found" means the log is readable but nothing was
        # logged since the step started: auditing is probably off, so unknown.
        return $null
    }
    if ($events.Count -eq 0) { return $null }
    foreach ($e in $events) {
        try {
            $xml = [xml]$e.ToXml()
            foreach ($d in @($xml.Event.EventData.Data)) {
                if ($d.Name -eq $Field) {
                    $leaf = [string]$d.'#text'
                    $i = $leaf.LastIndexOfAny([char[]]@('\', '/'))
                    if ($i -ge 0) { $leaf = $leaf.Substring($i + 1) }
                    if ($leaf -ieq $ImageName) { return $true }
                }
            }
        }
        catch { continue }
    }
    return $false
}

function Invoke-TtxVerifyCheck {
    param($Check, [hashtable]$Values, [string]$StepStartUtc)
    $type = [string]$Check['type']
    $r = @{ type = $type; target = ''; result = 'unknown'; detail = '' }
    $bad = Test-TtxVerifyDefinition $Check
    if ($bad.Count -gt 0) { $r.detail = ($bad -join '; '); return $r }
    try {
        switch ($type) {
            'file_exists' {
                $path = Expand-TtxVerifyText ([string]$Check['path']) $Values
                $r.target = $path
                if (Test-Path -LiteralPath $path) { $r.result = 'pass'; $r.detail = 'Present.' }
                else { $r.result = 'fail'; $r.detail = 'Not found.' }
            }
            'scheduled_task_exists' {
                $name = Expand-TtxVerifyText ([string]$Check['name']) $Values
                $r.target = $name
                if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                    $r.detail = 'Get-ScheduledTask is not available on this host.'
                    break
                }
                $taskPath = '\'
                $taskName = $name
                $i = $name.LastIndexOf('\')
                if ($i -ge 0) { $taskPath = $name.Substring(0, $i + 1); $taskName = $name.Substring($i + 1) }
                if ($Check['path']) { $taskPath = Expand-TtxVerifyText ([string]$Check['path']) $Values }
                $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if (-not $task -and $i -lt 0 -and -not $Check['path']) {
                    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                }
                if ($task) { $r.result = 'pass'; $r.detail = "Registered at $(@($task)[0].TaskPath)$(@($task)[0].TaskName)." }
                else { $r.result = 'fail'; $r.detail = 'No such scheduled task (or not visible to this user).' }
            }
            'registry_value_exists' {
                $key = Expand-TtxVerifyText ([string]$Check['key']) $Values
                $name = Expand-TtxVerifyText ([string]$Check['name']) $Values
                $r.target = if ($name) { "$key ($name)" } else { $key }
                $regPath = ConvertTo-TtxRegistryPath $key
                if (-not $regPath) { $r.detail = "Key must start with a hive such as HKCU\ or HKLM\ (got '$key')."; break }
                if (-not (Get-PSProvider -PSProvider Registry -ErrorAction SilentlyContinue)) {
                    $r.detail = 'The registry is not available on this host.'
                    break
                }
                if (-not (Test-Path -LiteralPath $regPath)) { $r.result = 'fail'; $r.detail = 'Key not found.'; break }
                if (-not $name) { $r.result = 'pass'; $r.detail = 'Key present.'; break }
                $prop = Get-ItemProperty -LiteralPath $regPath -Name $name -ErrorAction SilentlyContinue
                if ($null -ne $prop) { $r.result = 'pass'; $r.detail = "Value present: $([string]$prop.$name)" }
                else { $r.result = 'fail'; $r.detail = 'Key present, value not found.' }
            }
            'service_exists' {
                $name = Expand-TtxVerifyText ([string]$Check['name']) $Values
                $r.target = $name
                if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
                    $r.detail = 'Get-Service is not available on this host.'
                    break
                }
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($svc) { $r.result = 'pass'; $r.detail = "Service present (status $($svc.Status))." }
                else { $r.result = 'fail'; $r.detail = 'No such service.' }
            }
            'process_ran_since_step_start' {
                $name = Expand-TtxVerifyText ([string]$Check['name']) $Values
                $r.target = $name
                if ([string]::IsNullOrEmpty($StepStartUtc)) { $r.detail = 'The step has no recorded start time.'; break }
                $since = ([datetime]::Parse($StepStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime()
                $image = if ($name -match '\.[A-Za-z0-9]+$') { $name } else { "$name.exe" }
                # 1. Process-creation audit (Security 4688), 2. Sysmon event 1,
                # 3. a matching process that is still running.
                $sec = Test-TtxProcessInLog -LogName 'Security' -EventId 4688 -Since $since -ImageName $image -Field 'NewProcessName'
                if ($sec -eq $true) { $r.result = 'pass'; $r.detail = 'Found in Security event 4688.'; break }
                $sys = Test-TtxProcessInLog -LogName 'Microsoft-Windows-Sysmon/Operational' -EventId 1 -Since $since -ImageName $image -Field 'Image'
                if ($sys -eq $true) { $r.result = 'pass'; $r.detail = 'Found in Sysmon event 1.'; break }
                $base = [System.IO.Path]::GetFileNameWithoutExtension($image)
                $running = @(Get-Process -Name $base -ErrorAction SilentlyContinue | Where-Object {
                        try { $_.StartTime -ge $since } catch { $false }
                    })
                if ($running.Count -gt 0) { $r.result = 'pass'; $r.detail = "Running since the step started (PID $($running[0].Id))."; break }
                if ($sec -eq $false -or $sys -eq $false) {
                    $r.result = 'fail'
                    $r.detail = 'Process-creation events since the step started do not include it.'
                    break
                }
                $r.detail = 'Not running now, and no readable process-creation log (enable 4688 auditing or Sysmon, or run elevated) to tell whether it ran.'
            }
        }
    }
    catch {
        $r.result = 'unknown'
        $r.detail = "Check failed: $($_.Exception.Message)"
    }
    return $r
}

function Invoke-TtxVerifyChecks {
    param($Checks, [hashtable]$Values, [string]$StepStartUtc)
    return , @(foreach ($c in @($Checks)) {
            if ($null -eq $c) { continue }
            Invoke-TtxVerifyCheck -Check $c -Values $Values -StepStartUtc $StepStartUtc
        })
}
