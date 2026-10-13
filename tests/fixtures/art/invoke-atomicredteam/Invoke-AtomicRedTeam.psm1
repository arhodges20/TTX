# MOCK Invoke-AtomicRedTeam for TTX Control Center smoke tests.
#
# Behaves like the parts of the real module the control center uses
# (Invoke-AtomicTest with -TestGuids, -CheckPrereqs, -GetPrereqs, -Cleanup,
# -InputArgs, -ExecutionLogPath, -TimeoutSeconds; Get-AtomicTechnique -Path)
# and prints the same marker lines ("Prerequisites met:", "Exit code: N").
# It treats the current host as Windows so the fixture atomics run anywhere.
# Commands run in a child PowerShell process, as the real 'powershell'
# executor does. Set TTX_MOCK_ART_NO_GET=1 to hide Get-AtomicTechnique, so the
# catalog's powershell-yaml fallback can be tested.

function ConvertTo-MockObject {
    param($Node)
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Node.Keys) { $o[[string]$k] = ConvertTo-MockObject $Node[$k] }
        return [pscustomobject]$o
    }
    if ($Node -is [System.Collections.IList]) { return , @(foreach ($i in $Node) { ConvertTo-MockObject $i }) }
    return $Node
}

# Returns objects shaped like the real module's AtomicTechnique class:
# properties, not hashtables, and input_arguments as a hashtable.
function Get-AtomicTechnique {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Alias('FullName')][string]$Path)
    Import-Module powershell-yaml -ErrorAction Stop
    $raw = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($Path))
    $tests = @(foreach ($t in @($raw['atomic_tests'])) {
            $ia = @{}
            if ($t['input_arguments']) {
                foreach ($k in $t['input_arguments'].Keys) { $ia[[string]$k] = ConvertTo-MockObject $t['input_arguments'][$k] }
            }
            [pscustomobject]@{
                name                     = [string]$t['name']
                auto_generated_guid      = [string]$t['auto_generated_guid']
                description              = [string]$t['description']
                supported_platforms      = @($t['supported_platforms'])
                input_arguments          = $ia
                dependency_executor_name = [string]$t['dependency_executor_name']
                dependencies             = @(foreach ($d in @($t['dependencies'])) { if ($d) { ConvertTo-MockObject $d } })
                executor                 = ConvertTo-MockObject $t['executor']
            }
        })
    [pscustomobject]@{
        attack_technique = @($raw['attack_technique'])
        display_name     = [string]$raw['display_name']
        atomic_tests     = $tests
    }
}

function Invoke-MockCommand {
    param([string]$Command, [int]$TimeoutSeconds)
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { 'powershell.exe' }
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    $out = & $exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($out)) { Write-Host ([string]$line) }
    return @{ ExitCode = $code; ProcessId = $null }
}

function Merge-MockArgs {
    param([string]$Command, $Test, [hashtable]$InputArgs, [string]$Atomics)
    if ($null -eq $Command) { return $null }
    $values = @{}
    foreach ($k in $Test.input_arguments.Keys) { $values[$k] = [string]$Test.input_arguments[$k].default }
    if ($InputArgs) { foreach ($k in $InputArgs.Keys) { if ($values.ContainsKey($k)) { $values[$k] = [string]$InputArgs[$k] } } }
    foreach ($k in $values.Keys) { $Command = $Command.Replace('#{' + $k + '}', $values[$k]) }
    return $Command.Replace('$PathToAtomicsFolder', $Atomics).Replace('PathToAtomicsFolder', $Atomics)
}

function Invoke-AtomicTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$AtomicTechnique,
        [string[]]$TestGuids,
        [string]$PathToAtomicsFolder,
        [switch]$CheckPrereqs,
        [switch]$GetPrereqs,
        [switch]$Cleanup,
        [switch]$NoExecutionLog,
        [string]$ExecutionLogPath,
        [hashtable]$InputArgs,
        [int]$TimeoutSeconds = 120,
        [switch]$Force
    )
    Write-Host "PathToAtomicsFolder = $PathToAtomicsFolder`n"
    $yaml = Join-Path (Join-Path $PathToAtomicsFolder $AtomicTechnique) "$AtomicTechnique.yaml"
    if (-not (Test-Path -LiteralPath $yaml)) {
        Write-Host "ERROR: $yaml does not exist"
        return
    }
    $tech = Get-AtomicTechnique -Path $yaml
    $n = 0
    foreach ($test in $tech.atomic_tests) {
        $n++
        if ($TestGuids -and $TestGuids -notcontains $test.auto_generated_guid) { continue }
        if ($test.supported_platforms -notcontains 'windows') { continue }
        $testId = "$AtomicTechnique-$n $($test.name)"
        if ($CheckPrereqs) {
            Write-Host "CheckPrereq's for: $testId"
            $reasons = @()
            if ($test.executor.elevation_required -and $env:TTX_MOCK_ART_ELEVATED -ne '1') { $reasons += "Elevation required but not provided`n" }
            foreach ($dep in @($test.dependencies)) {
                $res = Invoke-MockCommand (Merge-MockArgs $dep.prereq_command $test $InputArgs $PathToAtomicsFolder) $TimeoutSeconds
                if ($res.ExitCode -ne 0) { $reasons += (Merge-MockArgs $dep.description $test $InputArgs $PathToAtomicsFolder) }
            }
            if ($reasons.Count -eq 0) { Write-Host "Prerequisites met: $testId" }
            else {
                Write-Host "Prerequisites not met: $testId"
                foreach ($r in $reasons) { Write-Host -NoNewline "`t[*] $r" }
                Write-Host "`nTry installing prereq's with the -GetPrereqs switch"
            }
        }
        elseif ($GetPrereqs) {
            Write-Host "GetPrereq's for: $testId"
            if (@($test.dependencies).Count -eq 0) { Write-Host 'No Preqs Defined'; continue }
            foreach ($dep in @($test.dependencies)) {
                $desc = (Merge-MockArgs $dep.description $test $InputArgs $PathToAtomicsFolder).Trim()
                Write-Host "Attempting to satisfy prereq: $desc"
                $check = Merge-MockArgs $dep.prereq_command $test $InputArgs $PathToAtomicsFolder
                if ((Invoke-MockCommand $check $TimeoutSeconds).ExitCode -eq 0) { Write-Host "Prereq already met: $desc"; continue }
                $null = Invoke-MockCommand (Merge-MockArgs $dep.get_prereq_command $test $InputArgs $PathToAtomicsFolder) $TimeoutSeconds
                if ((Invoke-MockCommand $check $TimeoutSeconds).ExitCode -eq 0) { Write-Host "Prereq successfully met: $desc" }
                else { Write-Host "Failed to meet prereq: $desc" }
            }
        }
        elseif ($Cleanup) {
            Write-Host "Executing cleanup for test: $testId"
            $null = Invoke-MockCommand (Merge-MockArgs $test.executor.cleanup_command $test $InputArgs $PathToAtomicsFolder) $TimeoutSeconds
            Write-Host "Done executing cleanup for test: $testId"
        }
        else {
            Write-Host "Executing test: $testId"
            $start = Get-Date
            $res = Invoke-MockCommand (Merge-MockArgs $test.executor.command $test $InputArgs $PathToAtomicsFolder) $TimeoutSeconds
            Write-Host "Exit code: $($res.ExitCode)"
            if (-not $NoExecutionLog -and $ExecutionLogPath) {
                [pscustomobject][ordered]@{
                    'Execution Time (UTC)'   = $start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    'Execution Time (Local)' = $start.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    'Technique'              = $AtomicTechnique
                    'Test Number'            = $n
                    'Test Name'              = $test.name
                    'Hostname'               = [Environment]::MachineName
                    'IP Address'             = '127.0.0.1'
                    'Username'               = [Environment]::UserName
                    'GUID'                   = $test.auto_generated_guid
                    'ProcessId'              = $res.ProcessId
                    'ExitCode'               = $res.ExitCode
                } | Export-Csv -Path $ExecutionLogPath -NoTypeInformation -Append
            }
            Write-Host "Done executing test: $testId"
        }
    }
}

$exports = @('Invoke-AtomicTest')
if ($env:TTX_MOCK_ART_NO_GET -ne '1') { $exports += 'Get-AtomicTechnique' }
Export-ModuleMember -Function $exports
