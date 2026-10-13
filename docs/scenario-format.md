# Scenario format (schemaVersion 2)

A scenario is one JSON file, `scenarios/<id>.json`; the file name must equal
the scenario `id`. It is an ordered chain of steps that the facilitator runs
all at once or one step at a time. Each attack step references one
**Atomic Red Team test** by its `auto_generated_guid` (decision D19); the
command that runs comes from the atomics installed on the lab host, never
from this repo.

Scenarios are normally created and edited in the **Scenario builder** tab,
which picks tests from the ART catalog and writes this format. Hand edits are
fine; the control center validates the file on every load.

## Top-level fields

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `2`. |
| `id` | yes | Letters, digits, `-`, `_`; equals the file name. |
| `name` | yes | Display name. |
| `summary` | no | One or two sentences shown in the UI. |
| `objectives` | no | Array of strings (what trainees should find). |
| `notes` | no | Array of strings for whoever edits the scenario. |
| `parameters`, `profileParameter`, `profiles` | no | Scenario-wide options with profile defaults (see below). Not used by ART steps; kept for stub tests and future scenario-wide settings. |
| `steps` | yes | Ordered array of steps. |

## ART step

```json
{
  "id": "persist-1",
  "title": "Persistence via scheduled task",
  "tactic": "Persistence",
  "technique": "T1053.005",
  "atomic_guid": "<chosen from the catalog>",
  "input_arguments": { "task_name": "TTX-Updater" },
  "depends_on": ["exec-1"],
  "verify": [ { "type": "scheduled_task_exists", "name": "#{task_name}" } ],
  "expected_detections": [ "Scheduled task created by powershell.exe" ],
  "hunt_notes": [ "Pivot from the task registration on {{Host}} to its action." ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique within the scenario. |
| `title` | yes | Display title. |
| `tactic` | no | ATT&CK tactic label, for the facilitator. |
| `technique` | yes* | ATT&CK id (`T1234` or `T1234.001`). Set from the chosen test; if it disagrees with the test's technique, the test's wins and a warning is shown. |
| `atomic_guid` | yes* | The ART test's `auto_generated_guid` (stable across ART updates, unlike test numbers). Empty = draft: the scenario can be saved but not loaded. A GUID not found in the installed atomics is a warning; that step can't run. |
| `input_arguments` | no | Overrides for the atomic's input arguments (strings). Arguments not set use the atomic's defaults; names the atomic doesn't define are ignored (warning). |
| `depends_on` | no | Earlier step ids that must have **succeeded** before this step runs. Enforced: running too early is refused with a warning, never silently skipped. |
| `verify` | no | Read-only checks run after the step (below). |
| `expected_detections` | no | Strings the facilitator expects to see in Falcon. They become the step's detection checklist rows (`exp-1`, `exp-2`, ...). |
| `hunt_notes` | no | Strings shown to the facilitator and in the answer key. `{{Host}}`, `{{Aid}}`, `{{SessionId}}` and `{{<input argument>}}` are filled in. |
| `high_impact_confirmation` | when required | For destructive/high-impact techniques (T1485, T1486, T1489, T1490, T1529, T1561 and their sub-techniques) this must equal the technique id. The builder sets it after the facilitator types the id; without it the scenario can't be saved or loaded. |

\* A step needs a `technique` or an `atomic_guid` that resolves to one.

## Verify checks

Declarative and read-only. They supplement ART's exit status by confirming the
step left the artifact the facilitator expects. Each result is **pass**,
**fail** or **unknown** (the check couldn't tell on this host). Values may use
`#{input_argument}`, `%VAR%` and `$env:VAR`.

| `type` | Fields | Passes when |
|---|---|---|
| `file_exists` | `path` | The file or folder exists. |
| `scheduled_task_exists` | `name` (`\Folder\Name` or `Name`), optional `path` | `Get-ScheduledTask` finds the task. |
| `registry_value_exists` | `key` (`HKCU\...`, `HKLM\...`, `HKEY_...`), optional `name` | The key (or the named value) exists. |
| `service_exists` | `name` | `Get-Service` finds the service. |
| `process_ran_since_step_start` | `name` (image, e.g. `schtasks.exe`) | Security 4688 or Sysmon event 1 shows it since the step started, or it is still running. `unknown` if neither log is readable and it has exited. |

A step **succeeds** when ART ran the test, the exit code is 0 (or not
reported) and no verify check **fails**. After cleanup, any check (other than
`process_ran_since_step_start`) that passed after the run and still passes is
reported as "still present", and that step's cleanup fails.

## Stub module step (tests only)

`{ "id", "title", "module": "stub-...", "params": {}, "depends_on": [] }`.
Runs a stub module from `modules/` (marker files only); see
[module-contract.md](module-contract.md). Scenarios with stub steps get an
`ArtifactFolder` parameter (default `TTX-Lab`, under `%ProgramData%`).

## Scenario parameters and profiles

Each parameter: `{ name, default, description, type?, choices? }`, with
`type` `string` (default), `choice` (one of `choices`) or `bool`. A scenario
can name one `choice` parameter as `profileParameter` and give a `profiles`
map; values resolve as **explicit value > the selected profile's value >
default** (D14).

## Validation levels

- **Errors** (bad JSON shape, duplicate or forward `depends_on`, unknown
  verify type, high-impact step without confirmation): not saved, not loaded.
- **Incomplete** (no steps, empty `atomic_guid`, a `<placeholder>` left in a
  verify check): saved as a draft, not loadable yet.
- **Warnings** (GUID not installed, technique mismatch, unknown input
  argument): shown; nothing blocked.

The shipped example, `scenarios/persistence-schtask.json` (T1059.001 ->
T1053.005), is deliberately incomplete: choose its tests in the builder on the
lab host.
