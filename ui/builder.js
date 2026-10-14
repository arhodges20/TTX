// TTX Control Center UI: ART catalog browser and scenario builder.
// Uses the helpers in app.js (el, api, $, asArray, showBanner, showView, ...).
// Steps only reference ART tests (GUID + input-argument overrides); this UI
// never edits attack commands.
'use strict';

const HIGH_IMPACT = ['T1485', 'T1486', 'T1489', 'T1490', 'T1529', 'T1561'];
const TACTICS = ['Reconnaissance', 'Resource Development', 'Initial Access', 'Execution', 'Persistence',
  'Privilege Escalation', 'Defense Evasion', 'Credential Access', 'Discovery', 'Lateral Movement',
  'Collection', 'Command and Control', 'Exfiltration', 'Impact'];
const VERIFY_TYPES = {
  file_exists: [['path', 'Path (may use #{arg}, %VAR%, $env:VAR)']],
  scheduled_task_exists: [['name', 'Task name (\\Folder\\Name or Name)']],
  registry_value_exists: [['key', 'Key, e.g. HKCU\\Software\\...'], ['name', 'Value name (optional)']],
  service_exists: [['name', 'Service name']],
  process_ran_since_step_start: [['name', 'Image name, e.g. schtasks.exe']],
};
const MAX_ROWS = 300;

function isHighImpact(techniqueId) {
  const base = String(techniqueId || '').trim().toUpperCase().split('.')[0];
  return HIGH_IMPACT.includes(base);
}

function linesOf(text) { return String(text || '').split(/\r?\n/).map(s => s.trim()).filter(Boolean); }

// Asks for the technique id to be typed back before a destructive/high-impact
// test is added. Returns the confirmation string or null.
function confirmHighImpact(techniqueId, testName) {
  const id = String(techniqueId || '').toUpperCase();
  const typed = window.prompt(`${id} is a destructive / high-impact technique` +
    (testName ? ` ("${testName}")` : '') + `.\n\nType ${id} to confirm adding it to the scenario.`);
  if (typed === null) return null;
  if (typed.trim().toUpperCase() !== id) { window.alert('Confirmation did not match; the test was not added.'); return null; }
  return id;
}

// ---------- catalog ----------

const Catalog = {
  tests: [],
  status: null,
  builtAt: null,
  loading: false,
  selectedGuid: null,
  pickFor: null,        // index of the builder step choosing a test, or null
  cache: {},            // guid -> full test record

  async load() {
    if (this.loading) return;
    this.loading = true;
    try {
      const d = await api('GET', '/api/catalog');
      this.tests = asArray(d.tests);
      this.status = d.status;
      this.builtAt = d.status ? d.status.builtAtUtc : null;
    } catch (e) {
      showBanner('Could not load the ART catalog: ' + e.message);
    } finally {
      this.loading = false;
    }
  },

  async show() {
    if (!this.tests.length) await this.load();
    this.renderStatus();
    this.renderRows();
    const note = $('catalog-pick-note');
    note.hidden = this.pickFor === null;
    if (this.pickFor !== null) {
      const st = Builder.draft && Builder.draft.steps[this.pickFor];
      fill(note, `Choosing a test for builder step "${st ? st.title || st.id : this.pickFor + 1}". Select a test, then "Use for this step". `,
        el('button', { class: 'btn btn-small', onclick: () => { this.pickFor = null; showView('builder'); } }, 'Cancel'));
    }
  },

  // Called on every poll with the server's catalog status.
  onStatus(st) {
    if (!st) return;
    const changed = st.status === 'ready' && st.builtAtUtc && st.builtAtUtc !== this.builtAt;
    this.status = st;
    if (changed && (this.tests.length || ui.view === 'catalog')) {
      this.load().then(() => { if (ui.view === 'catalog') { this.renderStatus(); this.renderRows(); } });
    } else if (ui.view === 'catalog') {
      this.renderStatus();
    }
  },

  renderStatus() {
    const s = this.status || {};
    const parts = [];
    if (s.building) parts.push(el('strong', null, 'Building catalog from the installed atomics... '));
    if (s.status === 'ready') {
      parts.push(`${s.count} Windows test(s) in ${s.techniqueCount} technique(s) from `, el('code', null, s.atomicsPath),
        ` · ART ${s.artVersion || '?'} · parsed with ${s.parser} · built ${fmtUtc(s.builtAtUtc)}`);
      if (s.stale) parts.push(' (atomics changed; rebuilding)');
    } else if (s.status === 'error') {
      parts.push(el('span', { class: 'err' }, 'Catalog unavailable: ' + (s.error || 'unknown error')));
    } else if (!s.building) {
      parts.push('No catalog yet.');
    }
    if (s.error && s.status === 'ready') parts.push(el('div', { class: 'err' }, 'Last rebuild failed: ' + s.error));
    if (asArray(s.parseErrors).length) parts.push(el('div', { class: 'warn' }, 'Some atomics could not be parsed: ' + asArray(s.parseErrors).join('; ')));
    fill($('catalog-status'), parts);
  },

  filtered() {
    const q = $('catalog-search').value.trim().toLowerCase();
    const tokens = q ? q.split(/\s+/) : [];
    const noElev = $('catalog-no-elev').checked;
    const noImpact = $('catalog-no-impact').checked;
    return this.tests.filter(t => {
      if (noElev && t.elevationRequired) return false;
      if (noImpact && t.highImpact) return false;
      if (!tokens.length) return true;
      const hay = `${t.techniqueId} ${t.techniqueName} ${t.testName} ${t.guid}`.toLowerCase();
      return tokens.every(tok => hay.includes(tok));
    });
  },

  renderRows() {
    const rows = this.filtered();
    const shown = rows.slice(0, MAX_ROWS);
    $('catalog-rows').replaceChildren(...shown.map(t => el('tr', {
      class: t.guid === this.selectedGuid ? 'selected' : '',
      onclick: () => this.select(t.guid),
    },
      el('td', null, el('strong', null, t.techniqueId), el('div', { class: 'sub' }, t.techniqueName)),
      el('td', null, `#${t.testNumber} ${t.testName}`),
      el('td', null, t.executor),
      el('td', null, flagTags(t)))));
    $('catalog-more').textContent = rows.length > MAX_ROWS
      ? `Showing ${MAX_ROWS} of ${rows.length} matches; refine the search.`
      : `${rows.length} match(es).`;
  },

  async getTest(guid) {
    if (!this.cache[guid]) this.cache[guid] = await api('GET', '/api/catalog/tests/' + encodeURIComponent(guid));
    return this.cache[guid];
  },

  async select(guid) {
    this.selectedGuid = guid;
    this.renderRows();
    const box = $('catalog-detail');
    box.classList.remove('muted');
    let t;
    try { t = await this.getTest(guid); } catch (e) { fill(box, el('div', { class: 'err' }, e.message)); return; }
    const actions = this.pickFor !== null
      ? el('button', { class: 'btn btn-primary', onclick: () => this.useForStep(t) }, 'Use for this step')
      : el('button', { class: 'btn btn-primary', onclick: () => this.addToBuilder(t) }, 'Add to scenario in builder');
    fill(box, 
      el('h3', null, `${t.techniqueId} ${t.techniqueName}`),
      el('div', null, el('strong', null, `#${t.testNumber} ${t.testName}`), ' ', flagTags(t)),
      el('table', { class: 'kv' },
        el('tr', null, el('th', null, 'GUID'), el('td', null, el('code', null, t.guid))),
        el('tr', null, el('th', null, 'Platforms'), el('td', null, asArray(t.platforms).join(', '))),
        el('tr', null, el('th', null, 'Executor'), el('td', null, t.executor)),
        el('tr', null, el('th', null, 'elevation_required'), el('td', { class: t.elevationRequired ? 'pf-warn' : null }, String(!!t.elevationRequired))),
        el('tr', null, el('th', null, 'Dependencies'), el('td', null, t.hasDependencies ? `${asArray(t.dependencies).length} prereq(s)${t.prereqDownloads ? ' - may download files' : ''}` : 'none'))),
      actions,
      el('h4', null, 'Description'), el('div', { class: 'desc' }, t.description || ''),
      el('h4', null, 'Input arguments'),
      asArray(t.inputArguments).length
        ? el('table', { class: 'kv' }, asArray(t.inputArguments).map(a => el('tr', null,
          el('th', null, a.name, el('div', { class: 'sub' }, a.type)),
          el('td', null, el('code', null, a.default), el('div', { class: 'sub' }, a.description)))))
        : el('div', { class: 'muted' }, 'none'),
      el('h4', null, 'Command (before substitution)'), codeBlock(t.command),
      t.cleanupCommand ? [el('h4', null, 'Cleanup command'), codeBlock(t.cleanupCommand)] : el('div', { class: 'muted' }, 'No cleanup command.'),
      asArray(t.dependencies).length ? [el('h4', null, 'Prereqs (what GetPrereqs would run)'), asArray(t.dependencies).map(d =>
        el('div', { class: 'dep' }, el('div', null, d.description, d.downloads ? [' ', tag('downloads', 'tag-danger')] : null),
          el('div', { class: 'sub' }, 'check:'), codeBlock(d.prereqCommand), el('div', { class: 'sub' }, 'get:'), codeBlock(d.getPrereqCommand)))] : null,
      el('div', { class: 'meta' }, 'From ', el('code', null, t.yamlPath)));
  },

  addToBuilder(t) {
    if (!Builder.draft) Builder.newScenario();
    if (Builder.addTest(t)) showView('builder');
  },

  useForStep(t) {
    const i = this.pickFor;
    this.pickFor = null;
    if (Builder.setTest(i, t)) showView('builder');
  },
};

function flagTags(t) {
  return [
    t.elevationRequired ? tag('elevation', 'tag-warn') : null,
    t.hasDependencies ? tag('prereqs') : null,
    t.prereqDownloads ? tag('prereq downloads', 'tag-danger') : null,
    t.commandDownloads ? tag('downloads', 'tag-warn') : null,
    t.highImpact ? tag('high impact', 'tag-danger') : null,
  ];
}

// ---------- builder ----------

const Builder = {
  draft: null,
  loadedId: null,     // id of the file the draft was opened from (overwrite without asking)

  async show() {
    this.renderOpenList();
    if (!this.draft) this.newScenario();
    else this.render();
  },

  renderOpenList() {
    const sel = $('b-open');
    fill(sel, el('option', { value: '' }, 'Open existing...'),
      ...ui.scenarios.map(s => el('option', { value: s.id }, `${s.name} (${s.id})`)));
    sel.onchange = () => { if (sel.value) this.open(sel.value); };
  },

  newScenario() {
    this.draft = { schemaVersion: 2, id: '', name: '', summary: '', objectives: [], steps: [] };
    this.loadedId = null;
    $('b-result').replaceChildren();
    this.render();
  },

  async open(id) {
    if (!id) return;
    try {
      const r = await api('GET', '/api/scenarios/' + encodeURIComponent(id));
      const s = r.scenario || {};
      s.steps = asArray(s.steps).map(st => Object.assign({
        input_arguments: {}, depends_on: [], verify: [], expected_detections: [], hunt_notes: [],
      }, st));
      this.draft = s;
      this.loadedId = id;
      showView('builder');
      this.showCheck(r, false);
    } catch (e) {
      showBanner(e.message);
    }
  },

  uniqueStepId(base) {
    const ids = new Set(this.draft.steps.map(s => s.id));
    base = String(base || 'step').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'step';
    let n = 1;
    while (ids.has(`${base}-${n}`)) n++;
    return `${base}-${n}`;
  },

  stepFromTest(t, confirmation) {
    const step = {
      id: this.uniqueStepId(t.techniqueId.replace('.', '-')),
      title: t.testName,
      tactic: '',
      technique: t.techniqueId,
      atomic_guid: t.guid,
      input_arguments: {},
      depends_on: [],
      verify: [],
      expected_detections: [],
      hunt_notes: [],
    };
    if (confirmation) step.high_impact_confirmation = confirmation;
    return step;
  },

  addTest(t) {
    let conf = null;
    if (t.highImpact || isHighImpact(t.techniqueId)) {
      conf = confirmHighImpact(t.techniqueId, t.testName);
      if (!conf) return false;
    }
    const step = this.stepFromTest(t, conf);
    const prev = this.draft.steps[this.draft.steps.length - 1];
    if (prev) step.depends_on = [prev.id];
    this.draft.steps.push(step);
    this.render();
    return true;
  },

  setTest(i, t) {
    const st = this.draft.steps[i];
    if (!st) return false;
    let conf = null;
    if (t.highImpact || isHighImpact(t.techniqueId)) {
      conf = confirmHighImpact(t.techniqueId, t.testName);
      if (!conf) return false;
    }
    st.atomic_guid = t.guid;
    st.technique = t.techniqueId;
    if (!st.title) st.title = t.testName;
    st.input_arguments = {};
    if (conf) st.high_impact_confirmation = conf; else delete st.high_impact_confirmation;
    this.render();
    return true;
  },

  // A step may only depend on steps above it. After a reorder, drop
  // dependencies that now point down (or at steps that no longer exist) and
  // say which were dropped.
  pruneDependencies() {
    const dropped = [];
    const above = new Set();
    for (const st of this.draft.steps) {
      const keep = asArray(st.depends_on).filter(d => above.has(d));
      for (const d of asArray(st.depends_on)) if (!keep.includes(d)) dropped.push(`${st.title || st.id} no longer depends on ${d}`);
      st.depends_on = keep;
      above.add(st.id);
    }
    return dropped;
  },

  move(i, delta) {
    const s = this.draft.steps;
    const j = i + delta;
    if (j < 0 || j >= s.length) return;
    [s[i], s[j]] = [s[j], s[i]];
    const dropped = this.pruneDependencies();
    this.render();
    fill($('b-result'), dropped.length
      ? el('div', { class: 'problems warn' }, 'Step order changed: ' + dropped.join('; ') + '. Re-tick "Depends on" if needed.')
      : null);
  },

  // Renaming a step id keeps other steps' dependencies pointing at it.
  renameStep(st, newId) {
    const oldId = st.id;
    st.id = newId;
    for (const o of this.draft.steps) {
      if (o !== st) o.depends_on = asArray(o.depends_on).map(d => (d === oldId ? newId : d));
    }
  },

  remove(i) {
    const st = this.draft.steps[i];
    if (!window.confirm(`Remove step "${st.title || st.id}"?`)) return;
    this.draft.steps.splice(i, 1);
    for (const o of this.draft.steps) o.depends_on = asArray(o.depends_on).filter(d => d !== st.id);
    this.render();
  },

  // Field bindings update the draft without re-rendering, so typing keeps focus.
  bind(input, obj, key, transform) {
    input.addEventListener('input', () => { obj[key] = transform ? transform(input.value) : input.value; });
    return input;
  },

  render() {
    const d = this.draft;
    for (const [id, key] of [['b-id', 'id'], ['b-name', 'name'], ['b-summary', 'summary']]) {
      const inp = $(id);
      inp.value = d[key] || '';
      inp.oninput = () => { d[key] = inp.value; };
    }
    const cont = $('b-continue');
    cont.checked = d.continue_on_failure === true;
    cont.onchange = () => { if (cont.checked) d.continue_on_failure = true; else delete d.continue_on_failure; };
    const obj = $('b-objectives');
    obj.value = asArray(d.objectives).join('\n');
    obj.oninput = () => { d.objectives = linesOf(obj.value); };
    $('b-notes').replaceChildren(...asArray(d.notes).map(n => el('div', null, n)));
    $('b-steps').replaceChildren(...d.steps.map((st, i) => this.renderStep(st, i)));
    if (!d.steps.length) $('b-steps').appendChild(el('li', { class: 'muted' }, 'No steps yet. Add tests from the ART catalog.'));
  },

  renderStep(st, i) {
    const steps = this.draft.steps;
    const testBox = el('div', { class: 'b-test' }, el('span', { class: 'muted' }, st.atomic_guid ? 'Loading test...' : 'No test chosen yet.'));
    const argsBox = el('div', { class: 'b-args' });
    const previewBox = el('div');
    const impact = !st.module && isHighImpact(st.technique);
    const isModule = !!st.module;

    const card = el('li', { class: 'step b-step' },
      el('div', { class: 'step-head' },
        el('span', { class: 'step-num' }, `${i + 1}.`),
        el('span', { class: 'step-title' }, st.title || st.id),
        el('button', { class: 'btn btn-small', disabled: i === 0, onclick: () => this.move(i, -1), title: 'Move up' }, '↑'),
        el('button', { class: 'btn btn-small', disabled: i === steps.length - 1, onclick: () => this.move(i, 1), title: 'Move down' }, '↓'),
        el('button', { class: 'btn btn-small btn-danger', onclick: () => this.remove(i) }, 'Remove')),
      el('div', { class: 'b-grid' },
        el('label', null, 'Step id', el('input', { value: st.id, oninput: (e) => this.renameStep(st, e.target.value) })),
        el('label', null, 'Title', this.bind(el('input', { value: st.title }), st, 'title')),
        el('label', null, 'Tactic', this.bind(el('input', { value: st.tactic || '', list: 'tactics' }), st, 'tactic')),
        isModule ? el('label', null, 'Module', el('input', { value: st.module, readonly: true }))
          : el('label', null, 'Technique', el('input', { value: st.technique || '', readonly: !!st.atomic_guid, title: 'Set from the chosen test' })),
        isModule ? null : el('label', { class: 'wide' }, 'ART test GUID (auto_generated_guid)',
          el('div', { class: 'row' }, el('input', { value: st.atomic_guid || '', readonly: true, placeholder: 'choose from the catalog' }),
            el('button', { class: 'btn btn-small', onclick: () => { Catalog.pickFor = i; showView('catalog'); } }, 'Pick from catalog')))),
      testBox,
      impact ? el('div', { class: 'warnbox' }, `${st.technique} is destructive / high-impact. Typed confirmation: `,
        el('code', null, st.high_impact_confirmation || '(none - saving will be refused)')) : null,
      el('h4', null, isModule ? 'Module parameters' : 'Input-argument overrides'), argsBox,
      el('h4', null, 'Depends on'),
      i === 0 ? el('div', { class: 'muted' }, 'First step: nothing to depend on.') :
        el('div', { class: 'deps' }, steps.slice(0, i).map(o => el('label', { class: 'check' },
          el('input', {
            type: 'checkbox', checked: asArray(st.depends_on).includes(o.id),
            onchange: (e) => {
              const set = new Set(asArray(st.depends_on));
              if (e.target.checked) set.add(o.id); else set.delete(o.id);
              st.depends_on = steps.filter(x => set.has(x.id)).map(x => x.id);
            },
          }), ` ${o.title || o.id}`))),
      isModule ? el('div', { class: 'muted' }, "Verify and cleanup come from the module's own Test-TtxVerify and Invoke-TtxCleanup.")
        : [el('h4', null, 'Verify (read-only checks after the run)'), this.renderVerify(st)],
      el('div', { class: 'b-grid' },
        el('label', { class: 'wide' }, 'Expected detections (one per line)',
          this.bind(el('textarea', { rows: 3 }, asArray(st.expected_detections).join('\n')), st, 'expected_detections', linesOf)),
        el('label', { class: 'wide' }, 'Hunt notes (one per line; {{Host}}, {{Edr}}, {{Aid}}, {{ElasticAgentId}}, {{<input arg>}} are filled in)',
          this.bind(el('textarea', { rows: 3 }, asArray(st.hunt_notes).join('\n')), st, 'hunt_notes', linesOf))),
      isModule ? null : el('div', { class: 'actions' }, el('button', { class: 'btn btn-small', onclick: () => this.preview(st, previewBox) }, 'Preview command with these inputs')),
      previewBox);

    if (isModule) this.fillModule(st, testBox, argsBox);
    else if (st.atomic_guid) this.fillTest(st, testBox, argsBox);
    else fill(argsBox, el('div', { class: 'muted' }, 'Choose a test to see its input arguments.'));
    return card;
  },

  // Module step: show the module's description and edit its parameters.
  async fillModule(st, testBox, argsBox) {
    const m = (await Modules.list()).find(x => x.id === st.module);
    if (!m || !m.ok) {
      fill(testBox, el('div', { class: 'warnbox' }, `Module '${st.module}' is not installed here${m && m.error ? ': ' + m.error : ''}. Import it on the Modules tab.`));
      fill(argsBox);
      return;
    }
    const info = m.info || {};
    fill(testBox, el('div', { class: 'step-module' }, `${m.builtIn ? 'Built-in' : 'Custom'} module `, el('strong', null, info.name || st.module),
      info.description ? ` \u00b7 ${info.description}` : '', info.requiresElevation ? [' ', tag('elevation', 'tag-warn')] : null));
    const defs = asArray(info.parameters);
    if (!defs.length) { fill(argsBox, el('div', { class: 'muted' }, 'This module has no parameters.')); return; }
    if (!st.params || typeof st.params !== 'object') st.params = {};
    fill(argsBox, el('table', { class: 'kv' }, defs.map(p => {
      const inp = el('input', { value: st.params[p.name] === undefined ? '' : String(st.params[p.name]), placeholder: `default: ${p.default === null ? '' : p.default}` });
      inp.addEventListener('input', () => { if (inp.value === '') delete st.params[p.name]; else st.params[p.name] = inp.value; });
      return el('tr', null, el('th', null, p.name), el('td', null, inp, el('div', { class: 'sub' }, p.description || '')));
    })));
  },

  // Adds a step that runs an installed module (built-in or imported).
  async addModuleStep() {
    const mods = (await Modules.list()).filter(m => m.ok);
    if (!mods.length) { showBanner('No modules installed. Import one on the Modules tab.'); return; }
    const choice = window.prompt('Module to add (id):\n' + mods.map(m => `${m.id}  -  ${(m.info || {}).name || ''}${m.builtIn ? ' (built-in)' : ''}`).join('\n'));
    if (choice === null) return;
    const m = mods.find(x => x.id === choice.trim());
    if (!m) { showBanner(`No module '${choice}'.`); return; }
    if (!this.draft) this.newScenario();
    const info = m.info || {};
    const prev = this.draft.steps[this.draft.steps.length - 1];
    this.draft.steps.push({
      id: this.uniqueStepId(m.id), title: info.name || m.id, tactic: info.tactic || '', module: m.id, params: {},
      depends_on: prev ? [prev.id] : [], verify: [],
      expected_detections: asArray(info.expectedDetections).map(d => d.description).filter(Boolean), hunt_notes: [],
    });
    showBanner('');
    this.render();
  },

  exportCurrent() {
    const id = String(this.draft && this.draft.id || '').trim();
    if (!id || !ui.scenarios.some(s => s.id === id)) { showBanner('Save the scenario before exporting it.'); return; }
    window.location.href = '/api/scenarios/' + encodeURIComponent(id) + '/export';
  },

  // Import a .ttx.json bundle or a plain scenario file. Bundles with module
  // code show the code first and need a tick before they are imported.
  async importFile(file) {
    let bundle;
    try { bundle = JSON.parse(await file.text()); } catch (e) { showBanner('That file is not valid JSON.'); return; }
    const scenario = bundle && bundle.ttxExport ? bundle.scenario : bundle;
    const mods = bundle && bundle.ttxExport ? asArray(bundle.modules) : [];
    if (!scenario || !scenario.id) { showBanner('No scenario found in that file.'); return; }
    const exists = ui.scenarios.some(s => s.id === scenario.id);
    const go = async () => {
      if (exists && !window.confirm(`A scenario "${scenario.id}" already exists here. Replace it?`)) return;
      try {
        const r = await api('POST', '/api/scenarios/import', { bundle, overwrite: exists, importModules: mods.length > 0 });
        showBanner('');
        await loadScenarios();
        this.renderOpenList();
        await this.open(r.id);
        Modules.invalidate();
        fill($('b-result'), el('div', { class: 'ok' }, `Imported "${r.id}"${asArray(r.importedModules).length ? ' with module(s) ' + asArray(r.importedModules).join(', ') : ''}.`),
          problemList('Not ready to load yet', r.incomplete, 'warn'), problemList('Warnings', r.warnings, 'warn'));
      } catch (e) { showBanner(e.message); }
    };
    if (!mods.length) { await go(); return; }
    const box = $('b-result');
    const ok = el('input', { type: 'checkbox' });
    const btn = el('button', { class: 'btn btn-primary', disabled: true, onclick: go }, 'Import scenario and modules');
    ok.addEventListener('change', () => { btn.disabled = !ok.checked; });
    fill(box, el('div', { class: 'prereq-gate' },
      el('strong', null, `"${scenario.id}" includes ${mods.length} custom module(s). Their code runs on this host as the control-center user:`),
      mods.map(m => el('details', null, el('summary', null, m.id), codeBlock(m.source))),
      el('label', { class: 'check' }, ok, ' I reviewed this code and want to import it'), btn));
    showView('builder');
  },

  async fillTest(st, testBox, argsBox) {
    let t;
    try { t = await Catalog.getTest(st.atomic_guid); }
    catch (e) {
      fill(testBox, el('div', { class: 'warnbox' }, `Test ${st.atomic_guid} is not in the installed atomics. Pick another test.`));
      fill(argsBox, );
      return;
    }
    fill(testBox, el('div', { class: 'step-module' }, `${t.techniqueId} ${t.techniqueName} · #${t.testNumber} `,
      el('strong', null, t.testName), ` · ${t.executor} `, flagTags(t)));
    const defs = asArray(t.inputArguments);
    if (!defs.length) { fill(argsBox, el('div', { class: 'muted' }, 'This test has no input arguments.')); return; }
    if (!st.input_arguments || typeof st.input_arguments !== 'object') st.input_arguments = {};
    fill(argsBox, el('table', { class: 'kv' }, defs.map(a => {
      const inp = el('input', { value: st.input_arguments[a.name] || '', placeholder: `default: ${a.default}` });
      inp.addEventListener('input', () => {
        if (inp.value === '') delete st.input_arguments[a.name]; else st.input_arguments[a.name] = inp.value;
      });
      return el('tr', null, el('th', null, a.name, el('div', { class: 'sub' }, a.type)),
        el('td', null, inp, el('div', { class: 'sub' }, a.description)));
    })));
  },

  renderVerify(st) {
    st.verify = asArray(st.verify);
    const box = el('div', { class: 'b-verify' });
    const draw = () => {
      fill(box, st.verify.map((c, k) => {
        const typeSel = el('select', {
          onchange: (e) => { st.verify[k] = { type: e.target.value }; draw(); },
        }, Object.keys(VERIFY_TYPES).map(v => el('option', { value: v, selected: c.type === v }, v)));
        const fields = (VERIFY_TYPES[c.type] || []).map(([f, ph]) => this.bind(el('input', { value: c[f] || '', placeholder: ph }), c, f));
        return el('div', { class: 'row' }, typeSel, fields,
          el('button', { class: 'btn btn-small', onclick: () => { st.verify.splice(k, 1); draw(); } }, 'Remove'));
      }), el('button', { class: 'btn btn-small', onclick: () => { st.verify.push({ type: 'file_exists' }); draw(); } }, 'Add check'));
    };
    draw();
    return box;
  },

  async preview(st, box) {
    if (!st.atomic_guid) { fill(box, el('div', { class: 'muted' }, 'Choose a test first.')); return; }
    try {
      const p = await api('POST', '/api/catalog/preview', { guid: st.atomic_guid, input_arguments: st.input_arguments || {} });
      fill(box, el('h4', null, 'Command'), codeBlock(p.command),
        p.cleanupCommand ? [el('h4', null, 'Cleanup command'), codeBlock(p.cleanupCommand)] : null,
        asArray(p.dependencies).length ? [el('h4', null, 'GetPrereqs commands'), asArray(p.dependencies).map(dp => codeBlock(dp.getPrereqCommand))] : null);
    } catch (e) {
      fill(box, el('div', { class: 'err' }, e.message));
    }
  },

  showCheck(r, saved) {
    const parts = [];
    if (saved) parts.push(el('div', { class: 'ok' }, `Saved to ${r.path}.`));
    parts.push(problemList('Errors', r.errors, 'err'));
    parts.push(problemList('Not ready to load yet', r.incomplete, 'warn'));
    parts.push(problemList('Warnings', r.warnings, 'warn'));
    fill($('b-result'), parts);
  },

  async save() {
    const d = this.draft;
    this.pruneDependencies();
    d.id = String(d.id || '').trim();
    const exists = ui.scenarios.some(s => s.id === d.id);
    let overwrite = false;
    if (exists) {
      if (d.id !== this.loadedId && !window.confirm(`A scenario "${d.id}" already exists. Replace it?`)) return;
      overwrite = true;
    }
    try {
      const r = await api('POST', '/api/scenarios', { scenario: d, overwrite });
      this.loadedId = d.id;
      this.showCheck(r, true);
      showBanner('');
      await loadScenarios();
      this.renderOpenList();
    } catch (e) {
      $('b-result').replaceChildren(el('div', { class: 'problems err' }, e.message));
    }
  },
};

window.Catalog = Catalog;
window.Builder = Builder;

window.addEventListener('DOMContentLoaded', () => {
  document.body.appendChild(el('datalist', { id: 'tactics' }, TACTICS.map(t => el('option', { value: t }))));
  let timer = null;
  $('catalog-search').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => Catalog.renderRows(), 150); });
  $('catalog-no-elev').addEventListener('change', () => Catalog.renderRows());
  $('catalog-no-impact').addEventListener('change', () => Catalog.renderRows());
  $('btn-rescan').addEventListener('click', async () => {
    try { Catalog.onStatus(await api('POST', '/api/catalog/rescan')); } catch (e) { showBanner(e.message); }
  });
  $('b-new').addEventListener('click', () => { if (window.confirm('Start a new scenario? Unsaved changes are lost.')) Builder.newScenario(); });
  $('b-add').addEventListener('click', () => { Catalog.pickFor = null; showView('catalog'); });
  $('b-save').addEventListener('click', () => Builder.save());
  $('b-add-module').addEventListener('click', () => Builder.addModuleStep());
  $('b-export').addEventListener('click', () => Builder.exportCurrent());
  $('b-import').addEventListener('click', () => $('b-import-file').click());
  $('b-import-file').addEventListener('change', (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) Builder.importFile(f); });
});
