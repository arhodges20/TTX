# TTX Control Center custom module template (D24).
#
# Copy this file, change it, and import it on the Modules tab. A module is one
# step type: Run does the step, Verify reports whether its artifact exists,
# Cleanup undoes it, and the facilitator sees the hunt text. It runs as the
# control-center user in a separate PowerShell process with no input
# (Windows PowerShell 5.1). Keep it benign and make Cleanup remove everything
# Run created. Contract: docs/module-contract.md.
#
# This example writes a small text file to %ProgramData%\<ArtifactFolder>.

function Get-TtxModuleInfo {
    @{
        Id                = 'example-note-file'     # informational; the import id is used
        Name              = 'Write a note file'
        Description       = 'Writes a text file to the artifact folder, then removes it on cleanup.'
        Version           = '1.0.0'
        Technique         = ''                      # ATT&CK id, e.g. T1105, if it applies
        Tactic            = ''
        IsStub            = $false
        RequiresElevation = $false                  # $true = blocked unless the control center is elevated
        TimeoutSeconds    = 60
        Parameters        = @(
            @{ Name = 'FileName'; Default = 'ttx-note.txt'; Description = 'File name to write.' },
            @{ Name = 'Text'; Default = 'TTX exercise note'; Description = 'Text to write.' }
        )
        ExpectedDetections = @(
            @{ Id = 'note-file'; Tactic = ''; Technique = ''; Description = 'File write to ProgramData by PowerShell' }
        )
    }
}

function Invoke-TtxRun {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $p = $Context.Parameters
    # New-TtxArtifactFile writes under Context.ArtifactRoot only and registers
    # the file as an artifact the facilitator sees.
    New-TtxArtifactFile -Context $Context -Name $p.FileName -Content "$($p.Text) (session $($Context.SessionId))" | Out-Null
    Write-TtxLog -Message "Wrote $($p.FileName)."
}

function Test-TtxVerify {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    if (Test-TtxArtifactFile -Context $Context -Name $Context.Parameters.FileName) {
        @{ Passed = $true; Detail = "$($Context.Parameters.FileName) is present." }
    }
    else {
        @{ Passed = $false; Detail = "$($Context.Parameters.FileName) is absent." }
    }
}

function Invoke-TtxCleanup {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    Remove-TtxArtifactFile -Context $Context -Name $Context.Parameters.FileName
}

function Get-TtxHunt {
    param([hashtable]$Context)
    @(
        @{ Title = 'New file in ProgramData'; Where = 'File creation events (EDR, Sysmon 11)'; What = 'A text file written under ProgramData by powershell.exe.' }
    )
}
