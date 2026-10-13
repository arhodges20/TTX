# Scenario format

Each scenario is a folder under `scenarios/` containing `scenario.json`. The
folder name must equal the scenario `id`.

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | Always `1` for now. |
| `id` | yes | Unique id; equals the folder name. |
| `name` | yes | Display name. |
| `summary` | no | One or two sentences shown in the UI. |
| `objectives` | no | Array of strings shown in the UI. |
| `parameters` | no | Array of parameter definitions (below). Values can be changed when the session is loaded; they override module defaults. |
| `profileParameter` | no | Name of a `choice` parameter whose value selects a set of defaults (below). |
| `profiles` | no | Map of profile name -> `{ option: value }`. Fills options the admin didn't set. |
| `steps` | yes | Ordered array of steps (below). |

Every scenario gets an `ArtifactFolder` parameter (default `TTX-Lab`), even if
it doesn't declare one. Artifacts go to `%ProgramData%\<ArtifactFolder>`
(D16; no per-session subfolder). `ArtifactFolder` must be a relative path
(letters, digits, space, `.`, `_`, `-`; nested folders allowed; no `..`); a
leading `%ProgramData%\` is accepted and stripped.

## Parameter definitions

Each entry: `{ name, default, description, type?, choices? }`.

| `type` | Meaning |
|---|---|
| `string` (default) | Free text. |
| `choice` | One of `choices` (an array of strings); any other value is rejected. |
| `bool` | `true`/`false` (also accepts `1/0`, `yes/no`, `on/off`). |

### Profiles

A scenario can name one `choice` parameter as its `profileParameter` and give a
`profiles` map. When a session loads, each option's value is resolved as:
**explicit value the admin set > the selected profile's value > the parameter
default**. This lets one switch (e.g. an intensity profile) preset several
options while still letting the admin override any of them. (The mechanism is
implemented and tested; the shipped scenario does not currently use it — see
decisions D14/D18.)

## Step fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique within the scenario (letters, digits, `-`, `_`). |
| `title` | yes | Display title. |
| `module` | yes | Module id; must exist as `modules/<module>/module.ps1`. |
| `dependsOn` | no | Array of earlier step ids that must have **succeeded** before this step can run. Enforced by the engine (and shown in the UI); running too early is refused, not silently skipped. |
| `params` | no | Object of parameter values for the module; overrides scenario parameters. |
| `facilitatorNotes` | no | Array of strings shown to the facilitator. |
