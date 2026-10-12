# Shared helpers for the engine, server, and step runner. Windows PowerShell 5.1.

# ConvertFrom-Json in PowerShell 5.1 returns PSCustomObjects and has no
# -AsHashtable switch. This converts its output to hashtables and arrays so the
# rest of the code can treat all data the same way.
function ConvertTo-TtxHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    # PowerShell 7 turns ISO date strings into DateTime; keep them as ISO strings.
    if ($InputObject -is [datetime]) { return $InputObject.ToString('o') }
    if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) {
        return $InputObject
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($key in $InputObject.Keys) {
            $h[[string]$key] = ConvertTo-TtxHashtable $InputObject[$key]
        }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $h[$prop.Name] = ConvertTo-TtxHashtable $prop.Value
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($item in $InputObject) { ConvertTo-TtxHashtable $item })
        return , $items
    }
    return $InputObject
}

function ConvertFrom-TtxJson {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    return ConvertTo-TtxHashtable (ConvertFrom-Json -InputObject $Json)
}

function ConvertTo-TtxJson {
    param($InputObject, [switch]$Compress)
    return ConvertTo-Json -InputObject $InputObject -Depth 12 -Compress:$Compress
}

# Writes UTF-8 (no BOM) text via a temp file + replace, so a crash mid-write
# never leaves a half-written state file.
function Write-TtxTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding $false
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, $encoding)
    if ([System.IO.File]::Exists($Path)) {
        # [NullString]::Value: PowerShell would pass $null to a string parameter as "".
        [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Read-TtxTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
