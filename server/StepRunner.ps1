<#
.SYNOPSIS
    Runs one module operation in isolation and writes one JSON result string.

.DESCRIPTION
    The engine runs this script in a background job (a separate powershell.exe)
    for 'run' and 'cleanup', and in a fresh runspace for 'describe'. It loads
    the shared marker helpers and the module, calls the contract functions, and
    returns:

        { ok, error, verify: { passed, detail }, info, hunt, logs: [ ... ],
          artifacts: [ { type, location, detail, ts } ], pid, data }

    See docs/module-contract.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [Parameter(Mandatory = $true)][ValidateSet('describe', 'run', 'cleanup')][string]$Operation,
    [string]$ContextJson,
    # File holding the context JSON (how the engine passes it).
    [string]$ContextPath
)

$ErrorActionPreference = 'Stop'
# The engine reads our result as UTF-8.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { Write-Verbose 'Console encoding not set.' }
$TtxLogBuffer = New-Object System.Collections.ArrayList
$TtxArtifactBuffer = New-Object System.Collections.ArrayList
$TtxStepData = @{}

function Write-TtxLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info'
    )
    [void]$TtxLogBuffer.Add(@{ ts = (Get-Date).ToString('o'); level = $Level; message = $Message })
}

# Records something the step created or ran on the host, for the facilitator.
function Register-TtxArtifact {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('file', 'scheduled-task', 'process')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Location,
        [string]$Detail = ''
    )
    [void]$TtxArtifactBuffer.Add(@{ ts = (Get-Date).ToString('o'); type = $Type; location = $Location; detail = $Detail })
}

# Saves a value in the step's recorded data (session state). Cleanup gets it
# back as $Context.StepData, even after a control-center restart.
function Set-TtxStepData {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        $Value
    )
    $TtxStepData[$Key] = $Value
}

function ConvertTo-TtxPairList {
    param($Items, [string[]]$Keys)
    return , @(foreach ($i in @($Items)) {
            if ($null -eq $i) { continue }
            if ($i -is [string]) { $h = @{}; $h[$Keys[0].ToLowerInvariant()] = $i; $h; continue }
            $h = @{}
            foreach ($k in $Keys) { $h[$k.ToLowerInvariant()] = [string]$i[$k] }
            $h
        })
}

function Invoke-TtxVerifyCheck {
    param([hashtable]$Context)
    $raw = @(Test-TtxVerify -Context $Context) | Select-Object -Last 1
    if ($raw -isnot [System.Collections.IDictionary] -or -not $raw.Contains('Passed')) {
        throw 'Test-TtxVerify must return a hashtable with Passed and Detail.'
    }
    return @{ passed = [bool]$raw['Passed']; detail = [string]$raw['Detail'] }
}

$result = @{
    ok        = $false
    error     = $null
    verify    = $null
    info      = $null
    hunt      = $null
    logs      = $TtxLogBuffer
    artifacts = $TtxArtifactBuffer
    pid       = $PID
    data      = $TtxStepData
}

try {
    . (Join-Path $PSScriptRoot 'TtxCommon.ps1')
    . (Join-Path $PSScriptRoot 'Preflight.ps1')
    . (Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') '_common') 'TtxArtifacts.ps1')

    if ($ContextPath) { $ContextJson = [System.IO.File]::ReadAllText($ContextPath, [System.Text.Encoding]::UTF8) }
    $context = ConvertFrom-TtxJson -Json $ContextJson
    if ($null -eq $context.Parameters) { $context.Parameters = @{} }
    if ($context.StepData -isnot [hashtable]) { $context.StepData = @{} }
    if ($context.AllStepData -isnot [hashtable]) { $context.AllStepData = @{} }
    # Start from what earlier runs recorded; the module may add to or replace it.
    foreach ($k in @($context.StepData.Keys)) { $TtxStepData[$k] = $context.StepData[$k] }

    if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        throw "Module file not found: $ModulePath"
    }
    . $ModulePath

    foreach ($fn in 'Get-TtxModuleInfo', 'Invoke-TtxRun', 'Test-TtxVerify', 'Invoke-TtxCleanup', 'Get-TtxHunt') {
        if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Module '$ModulePath' does not define $fn."
        }
    }

    # Parameters: module defaults < scenario/step values (already merged by the engine).
    $info = Get-TtxModuleInfo
    $params = @{}
    foreach ($p in @($info.Parameters)) {
        if ($null -ne $p) { $params[$p.Name] = $p.Default }
    }
    foreach ($key in @($context.Parameters.Keys)) { $params[$key] = $context.Parameters[$key] }
    $context.Parameters = $params

    switch ($Operation) {
        'describe' {
            $result.info = @{
                id                 = [string]$info.Id
                name               = [string]$info.Name
                description        = [string]$info.Description
                version            = [string]$info.Version
                technique          = [string]$info.Technique
                tactic             = [string]$info.Tactic
                isStub             = [bool]$info.IsStub
                timeoutSeconds     = [int]$info.TimeoutSeconds
                parameters         = @(foreach ($p in @($info.Parameters)) {
                        if ($null -ne $p) { @{ name = [string]$p.Name; default = $p.Default; description = [string]$p.Description } }
                    })
                expectedDetections = @(foreach ($d in @($info.ExpectedDetections)) {
                        if ($null -ne $d) { @{ id = [string]$d.Id; tactic = [string]$d.Tactic; technique = [string]$d.Technique; description = [string]$d.Description } }
                    })
            }
            # Hunt guidance: either a list of @{ Title; Where; What } (simple form)
            # or a hashtable with Items, Lineage, FalconEvents, WindowsEvidence,
            # Queries, and Pivots. Text may contain {{Placeholders}} that the
            # engine fills in with this run's values.
            $raw = Get-TtxHunt -Context $context
            $h = @{ items = @(); lineage = @(); falconEvents = @(); windowsEvidence = @(); queries = @(); pivots = @() }
            if ($raw -is [System.Collections.IDictionary]) {
                $h.items = ConvertTo-TtxPairList $raw['Items'] 'Title', 'Where', 'What'
                $h.lineage = @(@($raw['Lineage']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
                $h.falconEvents = ConvertTo-TtxPairList $raw['FalconEvents'] 'Name', 'Detail'
                $h.windowsEvidence = ConvertTo-TtxPairList $raw['WindowsEvidence'] 'Name', 'Detail'
                $h.queries = ConvertTo-TtxPairList $raw['Queries'] 'Title', 'Query'
                $h.pivots = @(@($raw['Pivots']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            }
            else {
                $h.items = ConvertTo-TtxPairList @($raw) 'Title', 'Where', 'What'
            }
            $result.hunt = $h
            $result.ok = $true
        }
        'run' {
            $null = Invoke-TtxRun -Context $context
            $result.verify = Invoke-TtxVerifyCheck -Context $context
            $result.ok = $result.verify.passed
            if (-not $result.ok) { $result.error = "Verify failed: $($result.verify.detail)" }
        }
        'cleanup' {
            $null = Invoke-TtxCleanup -Context $context
            $result.verify = Invoke-TtxVerifyCheck -Context $context
            $result.ok = -not $result.verify.passed
            if (-not $result.ok) { $result.error = "Artifact still present after cleanup: $($result.verify.detail)" }
        }
    }
}
catch {
    $result.ok = $false
    $result.error = $_.Exception.Message
}

ConvertTo-Json -InputObject $result -Depth 8 -Compress
