# TTX Control Center — Project Brief

> **PLACEHOLDER — the brief text has not been added yet.**
> The original brief was referenced but not supplied when this repo was
> created. Paste the full brief here; it is the source of truth for vision,
> principles, and scope, and it overrides anything below.

## What this product is

**TTX Control Center** is a local web tool a facilitator runs on a Windows lab
host to drive a hands-on EDR hunting exercise (CTF-style).

- The facilitator builds or loads a **scenario**: an ordered chain of steps,
  each of which references one **Atomic Red Team (ART)** test by its
  `auto_generated_guid`, plus input-argument overrides. Steps run one at a
  time or all at once, with dependency order enforced.
- **ART is the execution engine** (decision D19). The attack behavior comes
  from the ART tests installed on the lab host (`C:\AtomicRedTeam` by
  default). This repo contains **orchestration only**: scenarios, the control
  center, preflight, the ART catalog, verification, cleanup, the detection
  checklist and the answer key. It does not contain atomics, attack scripts or
  technique logic.
- Trainees ("analysts") hunt the resulting telemetry in their EDR console
  (CrowdStrike Falcon) and reconstruct what happened. The facilitator's view
  shows, per step, the atomic's description, the exact command that ran
  (from the installed YAML after input-argument substitution), the UTC window,
  read-only verify results, and the facilitator's hunt notes, and generates an
  **answer key**.
- After each run, the facilitator records which EDR **detections actually
  fired** in a checklist; results are saved so a scenario's expected-vs-actual
  detections can be tuned over time.
- **Cleanup** runs each executed test's ART cleanup in reverse order from
  saved session state, so it works even after the control center is
  restarted.

### Audiences

- **Analysts** hunt in the EDR console; they do not use this tool.
- **Facilitator (admin)** uses this tool to build scenarios, run steps, read
  the hunt notes and answer key, and record detections.

### Scope boundary

- No technique implementations in this repo (D19). New behavior means picking
  a different ART test, not writing code.
- Guardrails rather than restrictions on ART itself: elevated tests are
  blocked unless the control center is elevated; destructive/high-impact
  techniques need a typed confirmation to be added to a scenario; prereqs that
  download tools need confirmation before they are fetched.
- ART paths and command lines may be visible in Falcon telemetry and could tip
  off trainees. Hiding them is out of scope for now.
- The stub module step type (marker files only) remains, for testing the
  engine without ART.

## Interim working constraints (from the kickoff request)

Until the brief is added, work follows these constraints from the project owner:

- **Purpose:** a tool for running technical tabletop exercises (TTX) that
  generate **real, benign telemetry** for the EDR (CrowdStrike Falcon), so
  analysts have genuine artifacts to hunt for, CTF-style.
- **Two audiences:** analysts hunt in the EDR console; the facilitator (admin)
  uses this tool, which shows exactly what each step created and ran (file
  paths, task names, processes) so they can guide the hunt.
- **Target:** Windows PowerShell 5.1 on a Windows lab host.
- **Attack steps are ART tests** chosen by the facilitator from the installed
  catalog (D19); this repo adds no attack behavior of its own.
- **Every step has a working Cleanup** (ART `-Cleanup`), driven from recorded
  session state, so it still works after a control-center restart.
- **Standard user by default.** Any option that needs admin checks for
  elevation and fails clearly.
- **Detection is a requirement, not a side effect.** The facilitator picks ART
  tests whose behavior the EDR is likely to detect (the lab host runs a
  detect-only policy) and records which detections actually fired. The EDR
  does not have to be present for the tool to run.
- **Start super simple.** Do not build anything the brief lists as out of scope.
