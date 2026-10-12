# Shared marker-file helpers for TTX modules. Dot-sourced by the step runner.
# Marker files are inert JSON text files that stand in for exercise artifacts.

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

function Get-TtxMarkerPath {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Name
    )
    if ([string]::IsNullOrEmpty($Name)) { $Name = "$($Context.StepId).marker" }
    if ($Name -match '[\\/]' -or $Name -match '^\.\.?$') {
        throw "Invalid marker name '$Name'."
    }
    return Assert-TtxArtifactPath -Path (Join-Path $Context.ArtifactRoot $Name)
}

function New-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$Name
    )
    $path = Get-TtxMarkerPath -Context $Context -Name $Name
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $body = [ordered]@{
        ttxMarker   = $true
        note        = 'Inert TTX Control Center marker file. Safe to delete.'
        sessionId   = $Context.SessionId
        scenarioId  = $Context.ScenarioId
        stepId      = $Context.StepId
        description = $Description
        createdAt   = (Get-Date).ToString('o')
    }
    $json = ConvertTo-Json -InputObject $body -Depth 4
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-TtxLog -Message "Wrote marker file $path"
    return $path
}

function Test-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Name
    )
    $path = Get-TtxMarkerPath -Context $Context -Name $Name
    return (Test-Path -LiteralPath $path -PathType Leaf)
}

function Remove-TtxMarker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$Name
    )
    $path = Get-TtxMarkerPath -Context $Context -Name $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
        Write-TtxLog -Message "Removed marker file $path"
    }
    else {
        Write-TtxLog -Message "Marker file already absent: $path"
    }
}
