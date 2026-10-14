# HTTP API

Served on `http://localhost:<port>/` only. POSTs need the header
`X-TTX-Request: 1` (the UI sends it); requests with a non-localhost `Host`
are refused (D10).

| Method / path | Purpose |
|---|---|
| `GET /api/preflight` | Host, user, elevation, EDR/telemetry agents with IDs, ART status. |
| `GET /api/catalog` | Catalog status and test list (summary). |
| `GET /api/catalog/status` | Catalog status only. |
| `GET /api/catalog/tests/<guid>` | One test in full. |
| `POST /api/catalog/preview` | `{ guid, input_arguments }` → commands after substitution. |
| `POST /api/catalog/rescan` | Rebuild the catalog. |
| `GET /api/scenarios`, `GET /api/scenarios/<id>` | List / read scenarios with validation results. |
| `POST /api/scenarios` | `{ scenario, overwrite }` → save `scenarios/<id>.json`. |
| `POST /api/sessions` | `{ scenarioId, parameters }` → load a scenario. |
| `GET /api/session?since=<n>&rev=<r>` | Session (only if changed since `rev`) and new events. |
| `POST /api/session/steps/<id>/run` | Run one step. |
| `POST /api/session/run-all` | Run every step not yet succeeded. |
| `POST /api/session/stop` | Kill the running step (and its processes); drop the queue. |
| `POST /api/session/steps/<id>/getprereqs` | `{ confirm: true, confirmDownload: true }`. |
| `POST /api/session/options` | `{ continueOnFailure: true\|false }`. |
| `POST /api/session/steps/<id>/detections` | `{ detectionId, result: fired\|not-fired\|unknown, notes }`. |
| `POST /api/session/calibrate`, `/api/session/calibration` | Falcon calibration trigger and its result. |
| `POST /api/session/cleanup` | Clean up every step that ran. |
| `GET /api/session/answer-key` | The answer key (Markdown). |
