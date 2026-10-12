# Design decisions

Notable decisions, newest last. Each entry: decision, options considered, why.

## D1. Backend is Windows PowerShell 5.1 only

- **Decision:** The backend is a PowerShell 5.1 script using
  `System.Net.HttpListener`, bound to `http://localhost:<port>/` only.
- **Options:** PowerShell-only; Python (Flask); Node.js.
- **Why:** Nothing to install on the lab host, and modules are PowerShell
  anyway, so the whole tool is one language. Binding to `localhost` keeps it
  off the network.

## D2. UI is static HTML/CSS/JS with polling

- **Decision:** Plain HTML/CSS/JS served by the backend, no build step. The UI
  polls the server about once a second for status and new events.
- **Options:** SPA framework with a build step; Server-Sent Events/WebSockets.
- **Why:** No toolchain. `HttpListener` in a single-threaded PowerShell loop
  can't easily hold long-lived connections; one-second polling is plenty for a
  facilitator UI.

## D3. Scenarios are JSON

- **Decision:** Each scenario is `scenarios/<id>/scenario.json`.
- **Options:** JSON; YAML; PowerShell data files (`.psd1`).
- **Why:** PowerShell 5.1 reads JSON natively (`ConvertFrom-Json`) and the
  browser can too. YAML needs an extra module. `.psd1` isn't readable by the UI.

## D4. Module contract: five functions in one `module.ps1`

- **Decision:** A module is `modules/<id>/module.ps1` defining
  `Get-TtxModuleInfo`, `Invoke-TtxRun`, `Test-TtxVerify`, `Invoke-TtxCleanup`,
  `Get-TtxHunt`. A step "succeeds" only if Run doesn't throw and Verify passes;
  a cleanup "succeeds" only if Cleanup doesn't throw and Verify then fails
  (the artifact is gone).
- **Options:** PowerShell module manifests (`.psd1` + `.psm1`); separate script
  per operation; metadata in JSON next to the script.
- **Why:** One file per module is the easiest thing to read and review.
  Checking Verify after Cleanup proves the Cleanup works instead of trusting it.

## D5. Shared marker helpers, guarded to `%ProgramData%`

- **Decision:** Modules write markers through shared helpers that refuse any
  path outside `%ProgramData%`.
- **Options:** Each module handles its own paths.
- **Why:** One guard in one place, so a module bug or a bad parameter can't
  write or delete outside the lab folder.
