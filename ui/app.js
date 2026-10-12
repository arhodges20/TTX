// TTX Control Center UI. Plain JS, no build step.
// Polls GET /api/session about once a second for step status and new events.
'use strict';

const POLL_MS = 1000;

const ui = {
  scenarios: [],
  selectedScenarioId: null,
  sessionId: null,
  sessionJson: '',
  eventCount: 0,
  busy: false,
  openDetails: {},   // "<stepId>:hunt" -> true, so re-renders keep <details> open
};

// ---------- helpers ----------

function $(id) { return document.getElementById(id); }

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
  }
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

const STATUS_LABEL = {
  'pending': 'pending', 'queued': 'queued', 'running': 'running', 'succeeded': 'succeeded',
  'failed': 'failed', 'interrupted': 'interrupted', 'cleanup-queued': 'cleanup queued',
  'cleaning': 'cleaning', 'cleaned': 'cleaned', 'cleanup-failed': 'cleanup failed',
  'active': 'active', 'abandoned': 'abandoned',
};

function pill(status) {
  return el('span', { class: 'pill st-' + status }, STATUS_LABEL[status] || status);
}

// ---------- scenarios ----------

async function loadScenarios() {
  const data = await api('GET', '/api/scenarios');
  ui.scenarios = asArray(data.scenarios);
  renderScenarioList();
}

function renderScenarioList() {
  const list = $('scenario-list');
  list.replaceChildren();
  if (ui.scenarios.length === 0) {
    list.appendChild(el('li', { class: 'invalid' }, 'No scenarios found in /scenarios.'));
    return;
  }
  for (const s of ui.scenarios) {
    if (!s.valid) {
      list.appendChild(el('li', { class: 'invalid', title: asArray(s.errors).join('\n') },
        s.id, el('div', { class: 'sub' }, 'Invalid: ' + asArray(s.errors).join(' '))));
      continue;
    }
    list.appendChild(el('li', {
      class: s.id === ui.selectedScenarioId ? 'selected' : '',
      onclick: () => selectScenario(s.id),
    }, s.name, el('div', { class: 'sub' }, `${s.stepCount} step(s)`)));
  }
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
  $('sd-params').replaceChildren(...asArray(s.parameters).map(p =>
    el('div', { class: 'param' },
      el('label', { for: 'param-' + p.name }, p.name),
      el('input', { id: 'param-' + p.name, name: p.name, value: p.default === null ? '' : String(p.default) }),
      p.description ? el('div', { class: 'hint' }, p.description) : null)));
}

async function onLoadScenario(ev) {
  ev.preventDefault();
  if (!ui.selectedScenarioId) return;
  const parameters = {};
  for (const input of $('sd-params').querySelectorAll('input')) parameters[input.name] = input.value;
  try {
    const view = await api('POST', '/api/sessions', { scenarioId: ui.selectedScenarioId, parameters });
    showBanner('');
    applyView(view, true);
  } catch (e) {
    showBanner(e.message);
  }
}

// ---------- session ----------

async function post(path, confirmText) {
  if (confirmText && !window.confirm(confirmText)) return;
  try {
    const view = await api('POST', path);
    showBanner('');
    applyView(view, true);
  } catch (e) {
    showBanner(e.message);
  }
}

// eventsFromZero: true when view.events starts at the first event (POST
// responses, or a poll with since=0). Otherwise a session switch means the
// events belong to a different offset, so re-poll from zero.
function applyView(view, eventsFromZero) {
  const s = view.session;
  const newId = s ? s.sessionId : null;
  if (newId !== ui.sessionId) {
    ui.sessionId = newId;
    ui.sessionJson = '';
    ui.eventCount = 0;
    $('log').replaceChildren();
    if (!eventsFromZero) { setTimeout(poll, 0); return; }
  }
  ui.busy = !!view.busy;
  appendEvents(asArray(view.events), view.eventCount);
  const json = JSON.stringify([s, ui.busy]);
  if (json !== ui.sessionJson) {
    ui.sessionJson = json;
    renderSession(s);
  }
}

function renderSession(s) {
  $('no-session').hidden = !!s;
  $('session').hidden = !s;
  if (!s) return;
  const active = s.status === 'active';
  $('s-name').textContent = s.scenarioName;
  $('s-id').textContent = s.sessionId;
  $('s-root').textContent = s.artifactRoot;
  $('s-status').replaceWith(Object.assign(pill(s.status), { id: 's-status' }));
  $('btn-run-all').disabled = !active || ui.busy;
  $('btn-cleanup').disabled = !active;

  const steps = asArray(s.steps);
  $('steps').replaceChildren(...steps.map((st, i) => renderStep(st, i, active)));
}

function renderStep(st, index, active) {
  const info = st.info || {};
  const huntKey = st.id + ':hunt';
  const verify = st.verify;
  let result = null;
  if (st.error) result = el('div', { class: 'step-result err' }, st.error);
  else if (verify) result = el('div', { class: 'step-result' }, (st.lastOp === 'cleanup' ? 'Cleanup check: ' : 'Verify: ') + verify.detail);
  if (st.describeError) result = el('div', { class: 'step-result err' }, 'Module error: ' + st.describeError);

  const hunt = asArray(st.hunt);
  const details = hunt.length ? el('details', {
    open: !!ui.openDetails[huntKey],
    ontoggle: (e) => { ui.openDetails[huntKey] = e.target.open; },
  },
    el('summary', null, `Hunt guidance (${hunt.length})`),
    hunt.map(h => el('div', { class: 'hunt-item' },
      el('strong', null, h.title), el('br'),
      el('span', { class: 'muted' }, 'Where: '), h.where, el('br'),
      el('span', { class: 'muted' }, 'What: '), h.what))) : null;

  const notes = asArray(st.facilitatorNotes);
  return el('li', { class: 'step', 'data-status': st.status },
    el('div', { class: 'step-head' },
      el('span', { class: 'step-num' }, `${index + 1}.`),
      el('span', { class: 'step-title' }, st.title),
      pill(st.status),
      el('button', {
        class: 'btn btn-small',
        disabled: !active || ui.busy,
        onclick: () => post(`/api/session/steps/${encodeURIComponent(st.id)}/run`),
      }, 'Run step')),
    el('div', { class: 'step-module' },
      info.name || st.module, ' ',
      info.isStub ? el('span', { class: 'tag tag-stub' }, 'stub') : null, ' ',
      info.technique ? el('span', { class: 'tag' }, info.technique) : null),
    result,
    notes.length ? [el('h4', null, 'Facilitator notes'), el('ul', null, notes.map(n => el('li', null, n)))] : null,
    details);
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
    const view = await api('GET', '/api/session?since=' + since);
    setConn('ok');
    applyView(view, since === 0);
  } catch (e) {
    setConn('bad');
  } finally {
    polling = false;
  }
}

async function start() {
  $('sd-form').addEventListener('submit', onLoadScenario);
  $('btn-run-all').addEventListener('click', () => post('/api/session/run-all'));
  $('btn-cleanup').addEventListener('click', () =>
    post('/api/session/cleanup', 'Clean up every step of this session? Anything running will be stopped.'));
  try {
    await loadScenarios();
    setConn('ok');
  } catch (e) {
    setConn('bad');
    showBanner('Could not load scenarios: ' + e.message);
  }
  await poll();
  setInterval(poll, POLL_MS);
}

start();
