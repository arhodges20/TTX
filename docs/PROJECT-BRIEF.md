# TTX Control Center: project brief

> The original brief was never added to the repo. This summarizes the
> project owner's direction so far; replace it if a full brief appears.

## Purpose

Run hands-on EDR hunting exercises (CTF-style) on a Windows lab host. Each
scenario step runs a real Atomic Red Team test so trainees have genuine
telemetry to hunt in their EDR (CrowdStrike Falcon, Elastic, ...).

## Audiences

- **Trainees** hunt in the EDR console; they don't use this tool.
- **Facilitator** uses this tool to run scenarios, see exactly what ran, read
  hunt notes, record which detections fired, and get an answer key.

## Principles

- **ART is the execution engine** (D19). This repo is orchestration only: no
  atomics, attack scripts or technique logic. Facilitators can import their
  own modules at runtime (D24); those live outside the repo.
- **Every step can be cleaned up**, from saved state, even after a restart.
- **Standard user by default.** Anything needing admin is blocked with a
  clear message unless the console is elevated.
- **Guardrails, not restrictions:** typed confirmation for destructive
  techniques; confirmation before prereqs download anything.
- **Detections are recorded, not promised** (D13): the facilitator marks what
  fired; the tool runs with or without an EDR present.
- **Windows PowerShell 5.1**, no installs beyond ART and powershell-yaml.
- **Keep it simple.**

## Out of scope (for now)

- Hiding ART paths and command lines from trainees.
- Shipping technique code in this repo, or modifying atomics.
- Running against remote hosts.
