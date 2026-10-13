// TTX Control Center UI: shared helpers and the Exercise (facilitator) view.
// Plain JS, no build step. builder.js adds the ART catalog and the scenario
// builder. Polls GET /api/session about once a second; the session itself is
// only resent by the server when it changed (revision).
'use strict';

const POLL_MS = 1000;

const ui = {
  view: 'exercise',
  scenarios: [],
  selectedScenarioId: null,
  sessionId: null,
  session: null,
  extras: {},
  readyToHunt: null,
  catalog: null,
  revision: -1,
  renderKey: '',
  eventCount: 0,
  busy: false,
  openDetails: {},   // "<stepId>:<block>" -> true, so re-renders keep <details> open
  prereqAck: {},     // stepId -> { review, download } checkboxes for GetPrereqs
};

// ---------- helpers ----------

function $(id) { return document.getElementById(id); }

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (k === 'value') node.value = v;
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    node.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
  }
  return node;
}

// replaceChildren that accepts nested arrays and skips null/false, like el().
function fill(node, ...kids) {
  node.replaceChildren(...kids.flat(Infinity).filter(k => k !== null && k !== undefined && k !== false));
  return node;
}

function asArray(v) { return Array.isArray(v) ? v : (v === null || v === undefined ? [] : [v]); }

async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (method === 'POST') {
    opts.headers['X-TTX-Request'] = '1';
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body || {});
  }
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch (e) { /* non-JSON */ }
  if (!res.ok) throw new Error((data && data.error) || `${res.status} ${res.statusText}`);
  return data;
}

function showBanner(msg) {
  const b = $('banner');
  if (!msg) { b.hidden = true; b.textContent = ''; return; }
  b.textContent = msg;
  b.hidden = false;
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function setConn(state) {
  const c = $('conn');
  c.className = 'conn conn-' + state;
  c.textContent = { ok: 'connected', wait: 'connecting...', bad: 'server not reachable' }[state];
}

function fmtTime(ts) {
  const d = new Date(ts);
  return isNaN(d) ? String(ts || '') : d.toLocaleTimeString([], { hour12: false });
}

function fmtUtc(ts) {
  const d = new Date(ts);
  return isNaN(d) ? String(ts || '') : d.toISOString().replace('T', ' ').replace(/\.\d+Z$/, 'Z');
}

function codeBlock(text) { return el('pre', { class: 'code' }, String(text || '')); }

function tag(text, cls, title) { return el('span', { class: 'tag ' + (cls || ''), title: title || null }, text); }

// <details> that stays open across re-renders.
function keptDetails(key, summary, ...body) {
  return el('details', {
    open: !!ui.openDetails[key],
    ontoggle: (e) => { ui.openDetails[key] = e.target.open; },
  }, el('summary', null, summary), ...body);
}

const STATUS_LABEL = {
  'pending': 'pending', 'queued': 'queued', 'running': 'running', 'succeeded': 'succeeded',
  'failed': 'failed', 'interrupted': 'interrupted', 'cleanup-queued': 'cleanup queued',
  'cleaning': 'cleaning', 'cleaned': 'cleaned', 'cleanup-failed': 'cleanup failed',
  'prereqs-missing': 'prereqs missing', 'getting-prereqs': 'getting prereqs',
  'active': 'active', 'abandoned': 'abandoned', 'skipped': 'skipped',
};

function pill(status) {
  return el('span', { class: 'pill st-' + status }, STATUS_LABEL[status] || status);
}

function showView(name) {
  ui.view = name;
  for (const v of ['exercise', 'catalog', 'builder']) $('view-' + v).hidden = v !== name;
  for (const t of document.querySelectorAll('.tab')) t.classList.toggle('active', t.dataset.view === name);
  if (name === 'catalog' && window.Catalog) window.Catalog.show();
  if (name === 'builder' && window.Builder) window.Builder.show();
}

// ---------- scenarios ----------

async function loadScenarios() {
  const data = await api('GET', '/api/scenarios');
  ui.scenarios = asArray(data.scenarios);
  renderScenarioList();
  if (ui.selectedScenarioId) selectScenario(ui.selectedScenarioId);
}

function renderScenarioList() {
  const list = $('scenario-list');
  list.replaceChildren();
  if (ui.scenarios.length === 0) {
    list.appendChild(el('li', { class: 'invalid' }, 'No scenarios found in /scenarios. Create one in the Scenario builder.'));
    return;
  }
  for (const s of ui.scenarios) {
    let sub = `${s.stepCount} step(s)`;
    let cls = s.id === ui.selectedScenarioId ? 'selected' : '';
    if (!s.valid) { sub = 'Invalid'; cls += ' invalid'; }
    else if (!s.loadable) { sub += ' - needs setup'; cls += ' incomplete'; }
    list.appendChild(el('li', { class: cls, onclick: () => selectScenario(s.id) },
      s.name, el('div', { class: 'sub' }, sub)));
  }
}

function problemList(title, items, cls) {
  items = asArray(items);
  if (!items.length) return null;
  return el('div', { class: 'problems ' + cls }, el('strong', null, title), el('ul', null, items.map(x => el('li', null, x))));
}

function selectScenario(id) {
  ui.selectedScenarioId = id;
  renderScenarioList();
  const s = ui.scenarios.find(x => x.id === id);
  $('scenario-detail').hidden = !s;
  if (!s) return;
  $('sd-name').textContent = s.name;
  $('sd-summary').textContent = s.summary || '';
  $('sd-objectives').replaceChildren(...asArray(s.objectives).map(o => el('li', null, o)));
  fill($('sd-problems'),
    problemList('Errors', s.errors, 'err'),
    problemList('Not ready to load', s.incomplete, 'warn'),
    problemList('Warnings', s.warnings, 'warn'));
  $('sd-params').replaceChildren(...asArray(s.parameters).map(p => {
    let input;
    if (p.type === 'choice') {
      input = el('select', { id: 'param-' + p.name, name: p.name },
        asArray(p.choices).map(c => el('option', { value: c, selected: String(p.default) === c }, c)));
    } else {
      input = el('input', { id: 'param-' + p.name, name: p.name, value: p.default === null ? '' : String(p.default) });
    }
    return el('div', { class: 'param' },
      el('label', { for: 'param-' + p.name }, p.name), input,
      p.description ? el('div', { class: 'hint' }, p.description) : null);
  }));
  $('sd-load').disabled = !s.loadable;
}

async function onLoadScenario(ev) {
  ev.preventDefault();
  if (!ui.selectedScenarioId) return;
  const parameters = {};
  for (const input of $('sd-params').querySelectorAll('input, select')) parameters[input.name] = input.value;
  try {
    const view = await api('POST', '/api/sessions', { scenarioId: ui.selectedScenarioId, parameters });
    showBanner('');
    applyView(view, true);
  } catch (e) {
    showBanner(e.message);
  }
}

// ---------- preflight ----------

function pfRow(label, value, state) {
  return el('tr', null,
    el('th', null, label),
    el('td', { class: state ? 'pf-' + state : null }, value));
}

async function loadPreflight() {
  const box = $('preflight');
  box.replaceChildren(el('div', { class: 'muted' }, 'Checking...'));
  try {
    const pf = await api('GET', '/api/preflight');
    const art = pf.art || {};
    fill(box,
      el('table', { class: 'kv' },
        pfRow('Host', pf.host),
        pfRow('User', `${pf.user}${pf.elevated ? ' (elevated)' : ' (not elevated)'}`, pf.elevated ? 'ok' : null),
        pfRow('Falcon sensor', pf.falconService, pf.sensorRunning ? 'ok' : 'warn'),
        pfRow('Falcon AID', pf.aid || 'unknown', pf.aid ? 'ok' : 'warn'),
        pfRow('ART root', art.root, art.rootFound ? 'ok' : 'bad'),
        pfRow('ART module', art.moduleImportable ? `importable, version ${art.moduleVersion}` : (art.moduleFound ? 'found, not importable' : 'not found'), art.moduleImportable ? 'ok' : 'bad'),
        pfRow('Atomics', art.atomicsFound ? `${art.techniqueCount} technique folder(s)` : 'not found', art.atomicsFound ? 'ok' : 'bad'),
        pfRow('powershell-yaml', art.yamlAvailable ? art.yamlVersion : 'missing', art.yamlAvailable ? 'ok' : 'bad')),
      problemList('Warnings', pf.warnings, 'warn'));
  } catch (e) {
    box.replaceChildren(el('div', { class: 'err' }, 'Preflight failed: ' + e.message));
  }
}

// ---------- session ----------

async function post(path, body, confirmText) {
  if (confirmText && !window.confirm(confirmText)) return null;
  try {
    const view = await api('POST', path, body);
    showBanner('');
    applyView(view, true);
    return view;
  } catch (e) {
    showBanner(e.message);
    return null;
  }
}

// eventsFromZero: true when view.events starts at the first event (POST
// responses, or a poll with since=0). Otherwise a session switch means the
// events belong to a different offset, so re-poll from zero.
function applyView(view, eventsFromZero) {
  if (view.catalog) ui.catalog = view.catalog;
  if (!view.unchanged) {
    const s = view.session;
    const newId = s ? s.sessionId : null;
    if (newId !== ui.sessionId) {
      ui.sessionId = newId;
      ui.eventCount = 0;
      ui.renderKey = '';
      $('log').replaceChildren();
      if (!eventsFromZero) { ui.revision = -1; setTimeout(poll, 0); return; }
    }
    ui.session = s;
    ui.extras = view.stepExtras || {};
    ui.readyToHunt = view.readyToHunt;
  }
  ui.revision = view.revision;
  ui.busy = !!view.busy;
  appendEvents(asArray(view.events), view.eventCount);
  const key = `${ui.revision}|${ui.busy}`;
  if (key !== ui.renderKey) {
    ui.renderKey = key;
    renderSession(ui.session);
  }
}

function renderSession(s) {
  $('no-session').hidden = !!s;
  $('session').hidden = !s;
  if (!s) return;
  const active = s.status === 'active';
  $('s-name').textContent = s.scenarioName;
  $('s-id').textContent = s.sessionId;
  $('s-status').replaceWith(Object.assign(pill(s.status), { id: 's-status' }));
  const art = s.art || {};
  fill($('s-art'), 'ART ', el('code', null, art.root || '?'),
    art.version ? ` (version ${art.version})` : '', ' · host ', el('code', null, (s.preflight || {}).host || '?'),
    ' · AID ', el('code', null, (s.preflight || {}).aid || 'unknown'));
  const params = s.parameters || {};
  $('s-params-row').hidden = Object.keys(params).length === 0;
  $('s-params').replaceChildren(...Object.keys(params).sort().map(k =>
    el('code', { class: 'param-chip' }, `${k}=${params[k]}`)));
  $('btn-run-all').disabled = !active || ui.busy;
  $('btn-cleanup').disabled = !active;

  const r = ui.readyToHunt;
  fill($('hunt-ready'), r
    ? el('span', null, 'Telemetry may take a few minutes to appear in Falcon. Last step finished ',
      el('strong', null, fmtUtc(r.lastStepEndUtc)), '; ready to hunt at about ',
      el('strong', null, fmtUtc(r.readyAtUtc)), ` (${fmtTime(r.readyAtUtc)} local, ~${r.delayMinutes} min after).`)
    : 'Telemetry may take a few minutes to appear in Falcon after each step.');

  renderCalibration(s, active);
  const steps = asArray(s.steps);
  $('steps').replaceChildren(...steps.map((st, i) => renderStep(st, i, active)));
}

function renderCalibration(s, active) {
  const c = s.calibration;
  const box = $('calibration');
  const runBtn = el('button', {
    class: 'btn btn-small', disabled: !active,
    onclick: () => post('/api/session/calibrate', {}, 'Run the CrowdStrike test-detection trigger (choice.exe /m crowdstrike_sample_detection) on this host?'),
  }, c ? 'Run calibration again' : 'Run Falcon calibration');
  if (!c) {
    box.replaceChildren(el('span', { class: 'muted' }, 'Calibration: confirm Falcon raises a test detection before the exercise. '), runBtn);
    return;
  }
  const sel = el('select', {
    onchange: (e) => post('/api/session/calibration', { result: e.target.value, notes: c.notes || '' }),
  }, ['unknown', 'fired', 'not-fired'].map(v => el('option', { value: v, selected: c.result === v }, v)));
  fill(box, el('span', null, 'Calibration ', el('code', null, c.commandLine), ` ran ${fmtUtc(c.ranAtUtc)}. Detection in Falcon: `), sel, ' ', runBtn);
}

function renderStep(st, index, active) {
  return st.kind === 'module' ? renderModuleStep(st, index, active) : renderArtStep(st, index, active);
}

function stepHead(st, index, active, canRun, extraTags) {
  return el('div', { class: 'step-head' },
    el('span', { class: 'step-num' }, `${index + 1}.`),
    el('span', { class: 'step-title' }, st.title),
    extraTags,
    pill(st.status),
    el('button', {
      class: 'btn btn-small',
      disabled: !active || ui.busy || !canRun,
      onclick: () => post(`/api/session/steps/${encodeURIComponent(st.id)}/run`),
    }, 'Run step'));
}

function renderArtStep(st, index, active) {
  const a = st.atomic;
  const ex = ui.extras[st.id] || {};
  const blockedBy = asArray(ex.blockedBy);
  const tags = [
    st.tactic ? tag(st.tactic) : null,
    tag(a ? a.techniqueId : st.technique),
    a && a.elevationRequired ? tag('elevation', 'tag-warn', 'elevation_required: true') : null,
    a && a.hasDependencies ? tag('prereqs', null, 'This atomic has dependencies (prereqs).') : null,
    a && a.prereqDownloads ? tag('prereq downloads', 'tag-danger', 'GetPrereqs appears to download external files or tools.') : null,
    a && a.commandDownloads ? tag('downloads', 'tag-warn', 'The test command appears to download something.') : null,
    a && a.highImpact ? tag('high impact', 'tag-danger', 'Destructive / high-impact technique.') : null,
  ];
  const parts = [stepHead(st, index, active, !ex.blocker, tags)];

  parts.push(el('div', { class: 'step-module' }, a
    ? [`${a.techniqueId} ${a.techniqueName} · ART test #${a.testNumber} `, el('strong', null, a.testName),
      ` · ${a.executor} · GUID `, el('code', null, a.guid)]
    : ['ART test ', el('code', null, st.atomicGuid), ' — not found in the installed atomics.']));

  if (ex.blocker) parts.push(el('div', { class: 'warnbox' }, ex.blocker));
  if (blockedBy.length && st.status !== 'succeeded') {
    parts.push(el('div', { class: 'step-result muted' }, 'Waits for: ' + blockedBy.map(b => `${b.title} (${b.status})`).join(', ')));
  }
  if (st.error) parts.push(el('div', { class: 'step-result err' }, st.error));
  if (st.status === 'prereqs-missing' && a) parts.push(renderPrereqGate(st, active));

  if (a) {
    parts.push(keptDetails(st.id + ':desc', 'What the atomic does', el('div', { class: 'desc' }, a.description || '(no description)')));
    const ran = st.run && st.run.command;
    parts.push(el('h4', null, ran ? `Command that ran (${a.executor})` : `Command to run (${a.executor})`));
    parts.push(codeBlock(ran ? st.run.command : a.command));
    const vals = st.values || {};
    const keys = Object.keys(vals).sort();
    if (keys.length) {
      const over = st.inputArguments || {};
      parts.push(el('div', { class: 'args' }, 'Input arguments: ', keys.map(k =>
        el('code', { class: 'param-chip' + (k in over ? ' override' : ''), title: k in over ? 'override' : 'default' }, `${k}=${vals[k]}`))));
    }
  }

  if (st.run && st.run.startUtc) {
    const r = st.run;
    const code = r.exitCode === null || r.exitCode === undefined ? 'not reported' : `${r.exitCode}${r.exitCodeSource ? ' (' + r.exitCodeSource + ')' : ''}`;
    parts.push(el('div', { class: 'step-result' }, 'UTC window ', el('code', null, fmtUtc(r.startUtc)), ' to ',
      el('code', null, r.endUtc ? fmtUtc(r.endUtc) : '(running)'), ` · exit code ${code}`));
    if (r.output) parts.push(keptDetails(st.id + ':out', 'ART output', codeBlock(r.output)));
  }

  const vr = asArray(st.verifyResults);
  if (vr.length) {
    parts.push(el('h4', null, 'Verify (after run)'));
    parts.push(verifyTable(vr));
  } else if (asArray(st.verify).length) {
    parts.push(el('div', { class: 'step-result muted' }, `${asArray(st.verify).length} verify check(s) will run after the step.`));
  }

  if (st.cleanup) {
    const c = st.cleanup;
    parts.push(el('div', { class: 'step-result' }, 'Cleanup: ', pill(c.status === 'succeeded' ? 'cleaned' : c.status === 'failed' ? 'cleanup-failed' : c.status),
      c.atUtc ? ` ${fmtUtc(c.atUtc)}` : '', c.error ? el('span', { class: 'err' }, ' ' + c.error) : null));
    if (c.output) parts.push(keptDetails(st.id + ':cl', 'Cleanup output', codeBlock(c.output)));
  }

  const notes = asArray(ex.huntNotes);
  if (notes.length) parts.push(el('h4', null, 'Hunt notes'), el('ul', null, notes.map(n => el('li', null, n))));
  parts.push(renderChecklist(st, ex));
  return el('li', { class: 'step', 'data-status': st.status }, parts);
}

function verifyTable(rows) {
  return el('table', { class: 'verify' },
    el('tbody', null, rows.map(v => el('tr', null,
      el('td', null, v.type), el('td', null, el('code', null, v.target || '')),
      el('td', { class: 'vr-' + v.result }, v.result), el('td', { class: 'muted' }, v.detail || '')))));
}

// Missing prereqs: show what GetPrereqs would run and require confirmation.
function renderPrereqGate(st, active) {
  const a = st.atomic;
  const ack = ui.prereqAck[st.id] || (ui.prereqAck[st.id] = { review: false, download: false });
  const missing = asArray(st.prereqs && st.prereqs.missing);
  const btn = el('button', { class: 'btn btn-small btn-primary' }, 'Run GetPrereqs');
  const update = () => { btn.disabled = !active || ui.busy || !ack.review || (a.prereqDownloads && !ack.download); };
  btn.addEventListener('click', () => post(`/api/session/steps/${encodeURIComponent(st.id)}/getprereqs`,
    { confirm: ack.review, confirmDownload: ack.download }));
  update();
  return el('div', { class: 'prereq-gate' },
    el('strong', null, 'Prerequisites not met'),
    missing.length ? el('ul', null, missing.map(m => el('li', null, m))) : null,
    el('div', null, 'GetPrereqs would run these commands (', a.executor, '), as the control-center user:'),
    asArray(a.dependencies).map(d => el('div', { class: 'dep' },
      el('div', null, d.description, d.downloads ? [' ', tag('downloads', 'tag-danger')] : null),
      codeBlock(d.getPrereqCommand))),
    a.prereqDownloads ? el('div', { class: 'warnbox' }, 'These prereqs appear to download external files or tools onto the lab host.') : null,
    el('label', { class: 'check' }, el('input', { type: 'checkbox', checked: ack.review, onchange: (e) => { ack.review = e.target.checked; update(); } }),
      ' I reviewed these commands and want to run them'),
    a.prereqDownloads ? el('label', { class: 'check' }, el('input', { type: 'checkbox', checked: ack.download, onchange: (e) => { ack.download = e.target.checked; update(); } }),
      ' Allow the download') : null,
    el('div', null, btn));
}

// Expected-vs-actual detection checklist; each change is saved at once.
function renderChecklist(st, ex) {
  const rows = asArray(ex.detections);
  const save = (id, result, notes) => post(`/api/session/steps/${encodeURIComponent(st.id)}/detections`, { detectionId: id, result, notes });
  const addInput = el('input', { placeholder: 'Add a detection that fired but was not expected' });
  const addBtn = el('button', {
    class: 'btn btn-small', onclick: () => {
      const v = addInput.value.trim();
      if (v) save('custom:' + v, 'fired', '');
    },
  }, 'Add');
  return el('div', { class: 'checklist' },
    el('h4', null, 'Detections in Falcon (expected vs. actual)'),
    rows.length ? el('table', { class: 'detections' }, el('tbody', null, rows.map(r => {
      const sel = el('select', { onchange: (e) => save(r.id, e.target.value, notes.value) },
        ['unknown', 'fired', 'not-fired'].map(v => el('option', { value: v, selected: r.result === v }, v)));
      const notes = el('input', { value: r.notes || '', placeholder: 'notes', onchange: (e) => save(r.id, sel.value, e.target.value) });
      return el('tr', null, el('td', null, r.description, r.expected ? null : el('span', { class: 'muted' }, ' (not expected)')),
        el('td', null, sel), el('td', null, notes));
    }))) : el('div', { class: 'muted' }, 'No expected detections entered for this step.'),
    el('div', { class: 'add-row' }, addInput, addBtn));
}

function renderModuleStep(st, index, active) {
  const info = st.info || {};
  const ex = ui.extras[st.id] || {};
  const parts = [stepHead(st, index, active, !ex.blocker, [tag('stub', 'tag-stub'), info.technique ? tag(info.technique) : null])];
  parts.push(el('div', { class: 'step-module' }, `Stub module ${st.module}: ${info.name || ''}`));
  if (st.describeError) parts.push(el('div', { class: 'step-result err' }, 'Module error: ' + st.describeError));
  if (st.error) parts.push(el('div', { class: 'step-result err' }, st.error));
  else if (st.verify && st.verify.detail) parts.push(el('div', { class: 'step-result' }, 'Verify: ' + st.verify.detail));
  const artifacts = asArray(st.artifacts);
  if (artifacts.length) {
    const removed = st.status === 'cleaned';
    parts.push(el('h4', null, removed ? 'Artifacts (removed by cleanup)' : 'Artifacts'),
      el('ul', { class: 'artifacts' + (removed ? ' removed' : '') }, artifacts.map(a =>
        el('li', null, tag(a.type), ' ', el('code', null, a.location)))));
  }
  const notes = asArray(ex.huntNotes);
  if (notes.length) parts.push(el('h4', null, 'Hunt notes'), el('ul', null, notes.map(n => el('li', null, n))));
  parts.push(renderChecklist(st, ex));
  return el('li', { class: 'step', 'data-status': st.status }, parts);
}

function appendEvents(events, total) {
  const log = $('log');
  const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  for (const e of events) {
    if (e.seq < ui.eventCount) continue;
    log.appendChild(el('div', { class: 'log-row' },
      el('span', null, fmtTime(e.ts)),
      el('span', { class: 'lv-' + e.level }, e.level),
      el('span', { class: 'step-id', title: e.stepId || '' }, e.stepId || '-'),
      el('span', { class: 'msg lv-' + e.level }, e.message)));
  }
  if (typeof total === 'number') ui.eventCount = Math.max(ui.eventCount, total);
  if (nearBottom) log.scrollTop = log.scrollHeight;
}

// ---------- polling ----------

let polling = false;
async function poll() {
  if (polling) return;
  polling = true;
  try {
    const since = ui.eventCount;
    const view = await api('GET', `/api/session?since=${since}&rev=${ui.revision}`);
    setConn('ok');
    applyView(view, since === 0);
    if (window.Catalog) window.Catalog.onStatus(ui.catalog);
  } catch (e) {
    setConn('bad');
  } finally {
    polling = false;
  }
}

async function start() {
  for (const t of document.querySelectorAll('.tab')) t.addEventListener('click', () => showView(t.dataset.view));
  for (const a of document.querySelectorAll('[data-goto]')) a.addEventListener('click', (e) => { e.preventDefault(); showView(a.dataset.goto); });
  $('sd-form').addEventListener('submit', onLoadScenario);
  $('sd-edit').addEventListener('click', () => { if (window.Builder) window.Builder.open(ui.selectedScenarioId); });
  $('btn-preflight').addEventListener('click', loadPreflight);
  $('btn-run-all').addEventListener('click', () => post('/api/session/run-all'));
  $('btn-cleanup').addEventListener('click', () =>
    post('/api/session/cleanup', {}, 'Run ART cleanup for every step that ran, in reverse order? Anything running will be stopped.'));
  showView('exercise');
  try {
    await loadScenarios();
    setConn('ok');
  } catch (e) {
    setConn('bad');
    showBanner('Could not load scenarios: ' + e.message);
  }
  loadPreflight();
  await poll();
  setInterval(poll, POLL_MS);
}

window.addEventListener('DOMContentLoaded', start);
