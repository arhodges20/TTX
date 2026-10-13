# Scenario format (schemaVersion 2)

One JSON file per scenario: `scenarios/<id>.json` (file name = `id`). Usually
written by the Scenario builder; hand edits are validated on load.

## Scenario

| Field | Req. | Meaning |
|---|---|---|
| `schemaVersion` | yes | `2` |
| `id` | yes | Letters, digits, `-`, `_`; equals the file name. |
| `name` | yes | Display name. |
| `summary`, `objectives`, `notes` | no | Text shown in the UI. |
| `continue_on_failure` | no | `true` = sessions start with Continue past failed steps on (D20). |
| `parameters`, `profileParameter`, `profiles` | no | Scenario-wide options (used by stub tests; D14). |
| `steps` | yes | Ordered steps. |

## ART step

```json
{
  "id": "persist-1",
  "title": "Scheduled task created with schtasks.exe",
  "tactic": "Persistence",
  "technique": "T1053.005",
  "atomic_guid": "42f53695-ad4a-4546-abb6-7d837f644a71",
  "input_arguments": { "time": "06:00" },
  "depends_on": ["exec-1"],
  "verify": [ { "type": "scheduled_task_exists", "name": "spawn" } ],
  "expected_detections": [ "schtasks.exe /create from a command shell" ],
  "hunt_notes": [ "Task action {{task_command}} on {{Host}}." ]
}
```

| Field | Meaning |
|---|---|
| `atomic_guid` | The ART test's `auto_generated_guid`. Empty = draft (saves, won't load). Not installed = warning; that step can't run. |
| `technique` | ATT&CK id. If it disagrees with the test's, the test's wins (warning). |
| `input_arguments` | Overrides; unset arguments use the atomic's defaults. |
| `depends_on` | Earlier steps that must have succeeded (or, with Continue past failed steps, been attempted). |
| `verify` | Read-only checks after the run (below). |
| `expected_detections` | Rows of the step's detection checklist. |
| `hunt_notes` | Shown to the facilitator and in the answer key. Placeholders: `{{Host}}`, `{{Edr}}`, `{{Aid}}`, `{{ElasticAgentId}}`, `{{SessionId}}`, `{{<input argument>}}`. |
| `high_impact_confirmation` | Required for T1485, T1486, T1489, T1490, T1529, T1561 (and sub-techniques): must equal the technique id. |

## Verify checks

Read-only; result is pass, fail or unknown. Values may use `#{arg}`, `%VAR%`,
`$env:VAR`.

| `type` | Fields |
|---|---|
| `file_exists` | `path` |
| `scheduled_task_exists` | `name` (optional `path`) |
| `registry_value_exists` | `key` (`HKCU\...`, `HKLM\...`), optional `name` |
| `service_exists` | `name` |
| `process_ran_since_step_start` | `name` (image). Uses Security 4688 or Sysmon 1, else running processes. |

A step succeeds if ART ran it, the exit code is 0 (or unreported) and no
check fails. After cleanup, a check that still passes fails that step's
cleanup (`process_ran_since_step_start` excepted).

## Validation

- **Errors** (bad shape, forward `depends_on`, unknown verify type, missing
  high-impact confirmation): not saved or loaded.
- **Incomplete** (no steps, empty GUID, a `<placeholder>` in a verify check):
  saved as a draft, not loadable.
- **Warnings** (GUID not installed, technique mismatch, unknown input
  argument): shown only.

## Stub step (tests only)

`{ "id", "title", "module": "stub-...", "params": {}, "depends_on": [] }`;
see [module-contract.md](module-contract.md).
