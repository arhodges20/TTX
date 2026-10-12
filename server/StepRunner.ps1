<#
.SYNOPSIS
    Runs one module operation in isolation and writes one JSON result string.

.DESCRIPTION
    The engine runs this script in a background job (a separate powershell.exe)
    for 'run' and 'cleanup', and in a fresh runspace for 'describe'. It loads
    the shared marker helpers and the module, calls the contract functions, and
    returns:

        { ok, error, verify: { passed, detail }, info, hunt, logs: [ ... ],
          artifacts: [ { type, location, detail, ts } ], pid }

    See docs/module-contract.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [Parameter(Mandatory = $true)][ValidateSet('describe', 'run', 'cleanup')][string]$Operation,
    [Parameter(Mandatory = $true)][string]$ContextJson
)

$ErrorActionPreference = 'Stop'
$TtxLogBuffer = New-Object System.Collections.ArrayList
$TtxArtifactBuffer = New-Object System.Collections.ArrayList

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
}

try {
    . (Join-Path $PSScriptRoot 'TtxCommon.ps1')
    . (Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') '_common') 'TtxArtifacts.ps1')

    $context = ConvertFrom-TtxJson -Json $ContextJson
    if ($null -eq $context.Parameters) { $context.Parameters = @{} }

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
                id          = [string]$info.Id
                name        = [string]$info.Name
                description = [string]$info.Description
                version     = [string]$info.Version
                technique   = [string]$info.Technique
                isStub      = [bool]$info.IsStub
                parameters  = @(foreach ($p in @($info.Parameters)) {
                        if ($null -ne $p) { @{ name = [string]$p.Name; default = $p.Default; description = [string]$p.Description } }
                    })
            }
            $result.hunt = @(foreach ($h in @(Get-TtxHunt -Context $context)) {
                    if ($null -ne $h) { @{ title = [string]$h.Title; where = [string]$h.Where; what = [string]$h.What } }
                })
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
