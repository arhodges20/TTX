# MOCK of the Invoke-AtomicRedTeam module, for tests only (tests/fixtures/art).
# Mirrors the real module's layout and the output lines the control center
# reads; runs only the fixture atomics next to it.
@{
    RootModule        = 'Invoke-AtomicRedTeam.psm1'
    ModuleVersion     = '0.0.1'
    GUID              = '6b1f7a0e-2d55-4f2a-9a52-7d3d8b0c0001'
    Author            = 'TTX Control Center tests'
    Description       = 'MOCK Invoke-AtomicRedTeam for TTX Control Center smoke tests. Not the real module.'
    PowerShellVersion = '5.0'
    FunctionsToExport = @('Invoke-AtomicTest', 'Get-AtomicTechnique')
}
