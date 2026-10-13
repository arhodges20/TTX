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

> **Layout changed by D19:** scenarios are flat `scenarios/<id>.json` files.

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

## D6. Steps run in background jobs, one at a time

- **Decision:** Each Run/Cleanup runs via `Start-Job` → `server/StepRunner.ps1`
  in a separate `powershell.exe`. The server loop checks jobs between
  requests, so the UI stays responsive. Only one operation runs at a time;
  "Run all" and "Cleanup" are queues. Each job has a timeout (default 120 s).
  Module metadata and hunt guidance ("describe") are read in a short-lived
  in-process runspace when a session is loaded, because they don't touch the
  system and a job costs about a second to start.
- **Options:** Runspace pool in-process; `Start-Process` per step; run inline.
- **Why:** Jobs are built into 5.1, isolate crashes and hangs from the server,
  and can be stopped. One-at-a-time matches how a facilitator runs a TTX.

## D7. One active session; state saved after every change

- **Decision:** There is one current session. The engine writes
  `runs/<id>/state.json` (atomically) after every change and appends to
  `events.jsonl`. On start it restores the newest session whose status is
  still `active`. A new scenario can't be loaded while the current session has
  steps that ran, until Cleanup succeeds. Cleanup runs for **every** step
  (Cleanup is idempotent), in reverse order, and the session closes only when
  every step's Verify confirms its artifact is gone. Empty artifact folders are
  then removed; folders with unexpected content are left and reported.
- **Options:** Multiple concurrent sessions; cleanup only steps that ran;
  recursive delete of the artifact folder.
- **Why:** Keeps it simple and makes it hard to leave artifacts behind. A
  recursive delete would be simpler but could remove things the tool didn't
  create.

## D8. Artifact location

- **Decision:** Artifacts go to `%ProgramData%\<ArtifactFolder>\<SessionId>\`.
  `ArtifactFolder` is a scenario parameter (default `TTX-Lab`), validated as a
  relative path with no `..`. Session state and logs stay under `runs/`.
- **Why:** Requested by the project owner. Per-session subfolders keep
  sessions apart and make cleanup exact.

## D9. Checks without a Windows host

- **Decision:** Development checks run under PowerShell 7 on Linux:
  `tests/Test-Syntax.ps1`, `tests/Invoke-SmokeTest.ps1` (with `ProgramData`
  pointed at a temp folder), and PSScriptAnalyzer's `PSUseCompatibleSyntax`,
  `PSUseCompatibleCommands`, and `PSUseCompatibleTypes` rules targeting
  Windows PowerShell 5.1. Final verification is on the Windows lab host.
- **Why:** Catches 7-only syntax and most logic bugs before a lab round trip.

## D10. Localhost hardening for the API

- **Decision:** Bind only `http://localhost:<port>/`, reject any non-localhost
  `Host` header, and require an `X-TTX-Request: 1` header on every POST.
- **Options:** No checks (localhost-only binding); a session token.
- **Why:** A web page open in the same browser can't send that custom header
  cross-origin without a CORS preflight, which this server never approves, so
  another site can't trigger runs or cleanup. The Host check blocks DNS
  rebinding. Both are a few lines; a token adds setup for little extra benefit
  in a lab.

## D11. Real, benign artifacts instead of stubs

> **Superseded by D19.** Real artifacts now come from Atomic Red Team tests;
> our own technique modules were removed. Stub modules remain for tests.

- **Decision:** Modules create **real** host artifacts that the EDR records
  (files, scheduled tasks, processes), each of which is inert: e.g. a
  scheduled task whose action runs a script that only appends a line to a log
  file. Each step reports the artifacts it created (type, location, detail)
  and the PID it ran in, and the UI shows them to the facilitator. Stub
  modules remain for engine tests.
- **Options:** Keep stubs (marker files only); simulate telemetry by writing
  fake log entries.
- **Why:** The product's purpose is to give analysts genuine telemetry to hunt
  in CrowdStrike Falcon. Marker files don't produce the events analysts would
  look for (task registration, task-launched processes). Fake log entries
  wouldn't appear in the EDR at all.

## D12. Scheduled-task scenario: steps are ART tests, not our modules

> **Revised by D19.** The earlier design (a four-step loader/implant chain
> built from our own stand-in scripts and modules) is **withdrawn**; it was
> never built (see D18) and is now out of scope, because this repo no longer
> contains technique implementations.

- **Decision:** The scheduled-task scenario (`scenarios/persistence-schtask.json`)
  is a chain of Atomic Red Team tests: a T1059.001 (PowerShell) step followed
  by a T1053.005 (Scheduled Task) step that `depends_on` it. Each step only
  references an ART test by `auto_generated_guid` plus input-argument
  overrides; the commands come from the atomics installed on the lab host.
  Originally the shipped file left `atomic_guid` empty for the facilitator to
  pick on the lab host; superseded by D21, which ships ready-to-run scenarios
  with GUIDs.
- **Options:** Our own benign scheduled-task modules (Milestone 2, now
  removed); hardcoding GUIDs from one ART release.
- **Why:** ART tests are public, reviewed and widely used, so the commands are
  known quantities, and the repo carries no attack logic. Leaving the GUIDs to
  the lab host avoids pinning a test that a different ART version might not
  have.

## D13. Detections are likely, not guaranteed

- **Decision:** Each module lists the detections it is *likely* to trigger
  (tactic/technique level, "confirm in your tenant"). The facilitator marks
  which actually fired in a per-step checklist; results are saved to session
  state and the run's answer key so scenarios can be tuned over time.
- **Why:** CrowdStrike Falcon's detection logic (IOAs, ML) is proprietary and
  changes over time, and depends on the tenant's prevention policy. The tool
  can stack well-known suspicious indicators but cannot promise a detection.
  Expected-vs-actual records turn that uncertainty into data.

## D14. Scenario options and input-argument overrides

> **Revised by D19.** The `DetectionProfile`/`CreateMethod`/`EncodeCommand`/
> `HiddenWindow` options belonged to the withdrawn loader/implant chain and are
> dropped.

- **Decision:** A step's behavior is tuned only through the ART test's own
  `input_arguments`: the step stores overrides, and anything it doesn't set
  takes the atomic's default. The facilitator sets overrides in the scenario
  builder. The engine's scenario-level option mechanism (typed `parameters`,
  `profileParameter`/`profiles`, explicit value > profile value > default)
  stays for scenario-wide settings such as `ArtifactFolder`, and is still
  covered by tests through the stub fixture.
- **Why:** ART already defines what each test can vary and documents the
  defaults; inventing a second layer of attack options would mean writing
  technique logic, which D19 rules out.

## D15. Cleanup through ART, driven from saved session state

> **Revised by D19.** The earlier design (proving ownership of a task created by
> our own `schtasks.exe /create` code) is withdrawn with that code.

- **Decision:** Before a step's run job starts, the engine records in
  `runs/<id>/state.json` everything Cleanup needs: the ART root and atomics
  path, technique, `auto_generated_guid`, the resolved input arguments, and
  the substituted command and cleanup command. The step is marked `executed`
  from that moment, so a run that crashed or was interrupted is still cleaned
  up. Cleanup runs `Invoke-AtomicTest <technique> -TestGuids <guid> -Cleanup
  -InputArgs <recorded>` for every executed step, in reverse order, from that
  saved state, so it works after a control-center restart. A step's cleanup
  counts as succeeded only if ART's cleanup completed and the step's `verify`
  checks that passed after the run now fail (the artifact is gone). Steps that
  never ran are marked `skipped`.
- **Options:** Re-read the scenario on cleanup; clean only steps that
  succeeded; trust ART's cleanup without checking.
- **Why:** The scenario file can change between run and cleanup; the state
  file can't. Failed and interrupted runs may still leave artifacts. Checking
  afterwards proves the cleanup instead of trusting it (same idea as D4).
  Ownership rests on the recorded GUID and input arguments: Cleanup uses
  exactly the values the run used, so it targets the same artifacts.

## D16. Artifact folder without a per-session subfolder (supersedes D8)

- **Decision:** Files go directly in `%ProgramData%\<ArtifactFolder>` (default
  `TTX-Lab`; `%ProgramData%\TTX-Lab` is accepted too). Every file carries the
  run ID; Run refuses to overwrite a same-named file that lacks this run's ID.
- **Options:** Keep `<ArtifactFolder>\<SessionId>\` (D8).
- **Why:** Matches the requested layout, keeps paths realistic, and keeps the
  task action under schtasks' 261-character `/tr` limit. Safe because only one
  session can be active and the previous one must be cleaned up first.

## D17. Falcon preflight and calibration

> **Extended by D22:** preflight now also detects Elastic Agent, Elastic
> Defend and Sysmon.

- **Decision:** When a session is created, the engine records host, user, UTC
  time, `CSFalconService` status, and the sensor's AID (read from
  `HKLM\SYSTEM\CurrentControlSet\Services\CSAgent\Sim`, value `AG`). If the
  sensor isn't running the GUI warns; nothing is blocked. An optional
  calibration action runs CrowdStrike's benign test-detection trigger,
  `choice /m crowdstrike_sample_detection`, with `/t 5 /d Y` added so it can
  never wait for input.
- **Caveat:** The trigger command and AID location could not be verified
  against current CrowdStrike documentation from the development environment
  (it requires a support-portal login); confirm both in your tenant's docs.
  The `/t 5 /d Y` flags are our addition.
- **Why:** Proves the sensor and console generate detections before the
  exercise, using behavior only: no test files, hashes, or sensor tampering.

## D18. Scope of this build: benign scenario kept, emulation chain deferred

> **Superseded by D19** for what ships: the Milestone 2 modules and scenario
> are removed and steps are ART tests. Kept as the record of why the
> loader/implant chain was never built.

- **Decision:** This milestone ships the facilitator-facing tooling that makes
  an exercise usable, built on the existing Milestone 2 "Persistence via
  scheduled task" scenario (stage a benign script, register a real scheduled
  task, let it fire). It did **not** build the four-step loader/implant
  emulation chain from D12, nor its `DetectionProfile`/`CreateMethod`/
  `EncodeCommand` options or the `schtasks.exe /create` + encoded-command
  tradecraft.
- **What was built instead (and is tested):**
  - Engine support that the chain would have needed and that is useful on its
    own: typed scenario options with profile defaults, step `dependsOn`
    ordering, recorded step data for cleanup, and per-module timeouts (D16 and
    the engine commit).
  - Falcon preflight and calibration (D17).
  - Expected-vs-actual **detection checklist** and a per-run **answer key**
    (`runs/<id>/answer-key.md`) generated from the run's real values, plus
    structured hunt guidance (lineage, Falcon events, Windows evidence,
    starter queries, pivots) on the three scheduled-task modules.
- **Why:** The explicit loader/implant/encoded-persistence emulation is
  offensive-security tooling whose whole purpose is to resemble a real
  intrusion as closely as possible. Generating that crossed a line this
  assistant will not build, benign payload notwithstanding. The benign
  scheduled-task scenario still produces real, huntable EDR telemetry (a script
  write, a scheduled task, and `svchost (Schedule) -> powershell` launching it
  from ProgramData), so trainees can still pivot task -> action -> file ->
  writer. The difference from the deferred chain is the intensity and
  attacker-shaping of the tradecraft, not whether there is anything to hunt.
- **If the chain is picked up later:** D12-D15 are the design of record. The
  engine, checklist, answer-key, and hunt framework are already in place; a
  future author would add the modules and the scenario options, not rework the
  plumbing.

## D19. Atomic Red Team is the execution engine (direction change)

- **Decision:** Every attack step is an **Atomic Red Team (ART) test** run by
  the `Invoke-AtomicRedTeam` module installed on the lab host. This repo
  contains **orchestration only**: scenarios, the control center, preflight,
  the ART catalog, verification, cleanup, the detection checklist and the
  answer key. It contains **no** technique implementations: no new atomics,
  no custom attack scripts, no technique logic. A scenario step only
  references an ART test by `auto_generated_guid` (stable across ART updates,
  unlike test numbers) plus input-argument overrides.
  - ART root is configurable (default `C:\AtomicRedTeam`). The module is
    imported by path from `<root>\invoke-atomicredteam\Invoke-AtomicRedTeam.psd1`
    because it may not be on `$PSModulePath`; atomics are read from
    `<root>\atomics`.
  - The catalog is built from the installed atomics with the module's own
    `Get-AtomicTechnique` when it is exported, otherwise with
    `ConvertFrom-Yaml` from `powershell-yaml`, filtered to Windows tests.
  - A step runs as: check prereqs; if missing, show what GetPrereqs would do
    and require explicit confirmation; execute with a per-run
    `-ExecutionLogPath`; run the step's declarative, read-only `verify`
    checks. Cleanup follows D15.
  - Our earlier technique modules (`stage-script`, `register-scheduled-task`,
    `run-scheduled-task`) and their scenario are removed. The stub module step
    type (marker files only) is kept for engine tests.
  - Guardrails: elevated tests are blocked unless the control center is
    elevated; tests in destructive/high-impact techniques (T1485, T1486,
    T1489, T1490, T1529, T1561 and sub-techniques) need a typed confirmation
    to be added to a scenario; prereqs that download tools need confirmation
    before GetPrereqs runs; the UI notes that ART paths and command lines
    (`AtomicRedTeam`, `Invoke-AtomicTest`) may be visible in Falcon telemetry
    and could tip off trainees (hiding them is out of scope).
- **Options:** Keep writing our own modules (D11); wrap a different framework
  (e.g. Caldera); use ART but vendor selected atomics into this repo.
- **Why:** ART is a maintained, public, widely reviewed library of small
  technique tests with built-in prereq and cleanup handling. Using it keeps
  this repo to orchestration and moves the question "what exactly runs" to a
  public, auditable source installed on the lab host. Vendoring atomics would
  put attack commands back in this repo and drift from upstream.
- **Supersedes:** D11 (our own real modules), the module half of D4 for
  production steps (the module contract now applies to stub test steps only),
  and the scenario layout in D3 (scenarios are now flat `scenarios/<id>.json`
  files). D12, D14 and D15 are revised to match. D18's scope note still
  explains why the loader/implant chain was never built; D19 removes it from
  the plans altogether.

## D20. Continue past failed steps (option)

- **Decision:** A session option, **Continue past failed steps**, defaulting
  from the scenario's `continue_on_failure` (off unless set) and switchable in
  the session header. When on, Run all keeps going after a step fails or stops
  at missing prerequisites (with a warning in the event log), and a step's
  `depends_on` is met once the dependency has been *attempted* (succeeded,
  failed, or stopped at prereqs) rather than only when it succeeded. Order is
  still enforced: a step can't run before its dependencies have had their
  turn. When off, behavior is as before: Run all stops at the first failure
  and dependencies must succeed.
- **Options:** Always continue; per-step "run anyway" overrides; skip failed
  dependencies silently.
- **Why:** Some atomics fail on a given host (e.g. an old tool that no longer
  runs on current Windows) while the rest of the scenario is still worth
  running, since every attempt leaves huntable telemetry. Keeping it an
  explicit option preserves the stricter default for scenarios where a later
  step really needs an earlier one to have worked. Cleanup is unchanged: every
  step that ran (including failed ones) is cleaned up.

## D21. Built-in, ready-to-run scenarios

- **Decision:** Ship four scenarios with `atomic_guid` filled in
  (`discovery-first-look`, `persistence-schtask`, `persistence-run-key`,
  `collection-staging`), so the tool works out of the box. Tests were chosen
  from the current ART atomics with these rules: no `elevation_required`, no
  prereqs (so nothing is downloaded), anything left on the host has an ART
  cleanup command, no credential access, nothing destructive or high-impact,
  and nothing that reaches outside the host. Input arguments are overridden
  where that makes the artifact safer (the scheduled task runs once at 06:00;
  the Run value points at notepad.exe). Each step carries expected
  detections, hunt notes, and verify checks where it creates something.
- **Options:** Keep empty GUIDs (D12 as first written); ship many scenarios.
- **Why:** The facilitator asked for scenarios that load and run without
  setup. GUIDs are stable across ART updates; if a lab host's ART version
  lacks one, the existing "not found in the installed atomics" warning says so
  and the step can be re-picked in the builder. Commands still come from ART,
  not this repo (D19).

## D22. EDR-agnostic preflight (Falcon and Elastic)

- **Decision:** Preflight looks for several agents by their Windows service
  instead of only CrowdStrike: CrowdStrike Falcon (`CSFalconService`, AID
  from the registry as in D17), Elastic Agent (`Elastic Agent`; agent ID and
  version from `elastic-agent status --output json`, which needs an elevated
  console), Elastic Defend (`ElasticEndpoint`) and Sysmon (`Sysmon64` /
  `Sysmon`). It warns only when no EDR is running (or one is installed but
  stopped), not when Falcon specifically is missing. Labels in the UI and
  answer key name the EDR(s) actually running. The answer key adds per-step
  starter searches for each agent present (Kibana KQL by `host.name` for
  Elastic, Event Search by AID for Falcon, `Get-WinEvent` for Sysmon), marked
  "confirm field names in your tenant". The Falcon calibration trigger is
  shown only when Falcon is installed; there is no equivalent for Elastic
  (we don't plant test-malware files to trigger it).
- **Options:** A `-Edr` switch chosen by the facilitator; Falcon-only.
- **Why:** Lab hosts differ: some run Falcon, some only Elastic. Detecting
  what is there needs no configuration, and the rest of the tool (checklist,
  answer key, ready-to-hunt estimate) is already EDR-neutral. Older session
  files without agent data still read as Falcon-only.

