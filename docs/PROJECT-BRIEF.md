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
- **Every step has a working Cleanup**, driven from recorded session state,
  so it still works after a control-center restart.
- **Stand-in files are labelled.** Every stand-in file starts with a comment
  identifying it as a TTX training artifact and includes the run ID, so a SOC
  can always confirm it is benign.
- **Standard user by default.** Any option that needs admin checks for
  elevation and fails clearly.
- **Detection is a requirement, not a side effect.** Behavior stays benign,
  but steps use attacker-shaped tradecraft so the EDR's behavioral logic is
  likely to raise a detection (the lab host runs a detect-only policy).
  Detection must come from behavior, never from planted malware signatures,
  hashes, EICAR-style files, or anything that tampers with or evades the
  sensor. The EDR does not have to be present for the tool to run.
- **Start super simple.** Do not build anything the brief lists as out of scope.
