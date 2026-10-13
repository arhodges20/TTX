# TTX Control Center — Project Brief

> **PLACEHOLDER — the brief text has not been added yet.**
> The original brief was referenced but not supplied when this repo was
> created. Paste the full brief here; it is the source of truth for vision,
> principles, and scope, and it overrides anything below.

## What this product is

**TTX Control Center** is a local web tool a facilitator runs on a Windows lab
host to drive a hands-on EDR hunting exercise (CTF-style).

- The facilitator loads a **scenario** (an ordered set of steps) and runs the
  steps one at a time or all together.
- Each step performs a small, **real but benign** action on the host that an
  EDR records: writing a script to `%ProgramData%`, registering a real
  scheduled task, letting that task fire so the Task Scheduler launches
  PowerShell. The payloads are inert (a script that only appends a line to a
  log file), but the activity is genuine, so there is real telemetry to hunt.
- Trainees ("analysts") hunt that telemetry in their EDR console and
  reconstruct what happened. The facilitator's view in this tool shows exactly
  what each step created and ran (file paths, task name, process IDs) plus
  per-step **hunt guidance** and a generated **answer key**, so the facilitator
  can guide the hunt and check answers.
- After each run, the facilitator records which EDR **detections actually
  fired** in a checklist; results are saved so a scenario's expected-vs-actual
  detections can be tuned over time.
- **Cleanup** removes every artifact and works even after the control center is
  restarted, because each step records what it created in session state.

### Audiences

- **Analysts** hunt in the EDR console; they do not use this tool.
- **Facilitator (admin)** uses this tool to run steps, read the hunt guidance
  and answer key, and record detections.

### Scope boundary (see decisions D18)

The tool intentionally stops at **benign, real activity**. It does not build
attacker-emulation tradecraft whose purpose is to mimic a real intrusion as
closely as possible (loaders/implants, encoded/obfuscated persistence, EDR
evasion). A proposed loud/subtle emulation chain is recorded as a design
(decisions D12-D15) but was deliberately not built; the shipped scenario stays
on the benign side of that line while still producing genuine, huntable events.

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
