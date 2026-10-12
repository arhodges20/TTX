# Shared artifact helpers for TTX modules. Dot-sourced by the step runner.
# Every file a module creates goes through these helpers, which keep it inside
# the session's artifact folder under %ProgramData% and report it to the
# facilitator via Register-TtxArtifact (provided by the step runner).

function Assert-TtxArtifactPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrEmpty($env:ProgramData)) {
        throw 'ProgramData environment variable is not set.'
    }
    $base = [System.IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($base + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch '$full': artifacts must live under '$base'."
    }
    return $full
}

# Full path of a file directly inside the session's artifact folder.
function Get-TtxArtifactPath {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Name -match '[\\/]' -or $Name -match '^\.\.?$' -or $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Invalid artifact file name '$Name'."
    }
    return Assert-TtxArtifactPath -Path (Join-Path $Context.ArtifactRoot $Name)
}

function New-TtxArtifactFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [string]$Detail = ''
    )
    $path = Get-TtxArtifactPath -Context $Context -Name $Name
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding $false))
    Write-TtxLog -Message "Wrote file $path"
    Register-TtxArtifact -Type file -Location $path -Detail $Detail
    return $path
}

function Test-TtxArtifactFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return (Test-Path -LiteralPath (Get-TtxArtifactPath -Context $Context -Name $Name) -PathType Leaf)
}

function Remove-TtxArtifactFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $path = Get-TtxArtifactPath -Context $Context -Name $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-TtxLog -Message "Removed file $path"
    }
    else {
        Write-TtxLog -Message "File already absent: $path"
    }
}

# Marker files: inert JSON notes, used by the stub modules. Name defaults to
# '<StepId>.marker'.

function New-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$Name
    )
    if ([string]::IsNullOrEmpty($Name)) { $Name = "$($Context.StepId).marker" }
    $body = [ordered]@{
        ttxMarker   = $true
        note        = 'Inert TTX Control Center marker file. Safe to delete.'
        sessionId   = $Context.SessionId
        scenarioId  = $Context.ScenarioId
        stepId      = $Context.StepId
        description = $Description
        createdAt   = (Get-Date).ToString('o')
    }
    return New-TtxArtifactFile -Context $Context -Name $Name -Content (ConvertTo-Json -InputObject $body -Depth 4) -Detail $Description
}

function Test-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Name
    )
    if ([string]::IsNullOrEmpty($Name)) { $Name = "$($Context.StepId).marker" }
    return Test-TtxArtifactFile -Context $Context -Name $Name
}

function Remove-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Name
    )
    if ([string]::IsNullOrEmpty($Name)) { $Name = "$($Context.StepId).marker" }
    Remove-TtxArtifactFile -Context $Context -Name $Name
}
