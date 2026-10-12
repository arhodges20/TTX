# TTX Control Center — Project Brief

> **PLACEHOLDER — the brief text has not been added yet.**
> The original brief was referenced but not supplied when this repo was
> created. Paste the full brief here; it is the source of truth for vision,
> principles, and scope, and it overrides anything below.

## Interim working constraints (from the kickoff request)

Until the brief is added, work follows these constraints from the project owner:

- **Purpose:** a tool for running technical tabletop exercises (TTX) that
  generate **real, benign telemetry** for the EDR (CrowdStrike Falcon), so
  analysts have genuine artifacts to hunt for, CTF-style.
- **Two audiences:** analysts hunt in the EDR console; the facilitator (admin)
  uses this tool, which shows exactly what each step created and ran (file
  paths, task names, processes) so they can guide the hunt.
- **Target:** Windows PowerShell 5.1 on a Windows lab host.
- **Benign by design:** artifacts are real but inert (e.g. a real scheduled
  task that runs a placeholder script which only writes a log/marker file).
  No functional malware, payloads, injection, credential access, or anything
  harmful outside a lab.
- **Every step has a working Cleanup.**
- **Start super simple.** Do not build anything the brief lists as out of scope.
