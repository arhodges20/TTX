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
| `parameters` | no | Array of `{ name, default, description }`. Values can be changed when the session is loaded; they override module defaults. |
| `steps` | yes | Ordered array of steps (below). |

Every scenario gets an `ArtifactFolder` parameter (default `TTX-Lab`), even if
it doesn't declare one. Artifacts go to
`%ProgramData%\<ArtifactFolder>\<SessionId>\`. `ArtifactFolder` must be a
relative path (letters, digits, space, `.`, `_`, `-`; nested folders allowed;
no `..`).

## Step fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique within the scenario (letters, digits, `-`, `_`). |
| `title` | yes | Display title. |
| `module` | yes | Module id; must exist as `modules/<module>/module.ps1`. |
| `params` | no | Object of parameter values for the module; overrides scenario parameters. |
| `facilitatorNotes` | no | Array of strings shown to the facilitator. |
