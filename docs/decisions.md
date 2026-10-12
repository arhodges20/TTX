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
