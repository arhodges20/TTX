// TTX Control Center UI: Modules tab (D24). Lists built-in and imported
// modules and imports new ones. Uses the helpers in app.js.
'use strict';

const Modules = {
  cache: null,

  invalidate() { this.cache = null; },

  async list() {
    if (!this.cache) {
      try { this.cache = asArray((await api('GET', '/api/modules')).modules); }
      catch (e) { showBanner('Could not list modules: ' + e.message); this.cache = []; }
    }
    return this.cache;
  },

  async show() {
    this.invalidate();
    this.render(await this.list());
  },

  render(mods) {
    const box = $('m-list');
    if (!mods.length) { fill(box, el('li', { class: 'muted' }, 'No modules.')); return; }
    fill(box, mods.map(m => {
      const info = m.info || {};
      const src = el('div');
      const view = el('details', {
        ontoggle: async (e) => {
          if (!e.target.open || src.childNodes.length) return;
          try { fill(src, codeBlock((await api('GET', '/api/modules/' + encodeURIComponent(m.id))).source)); }
          catch (err) { fill(src, el('div', { class: 'err' }, err.message)); }
        },
      }, el('summary', null, 'View code'), src);
      return el('li', { class: 'step' },
        el('div', { class: 'step-head' },
          el('span', { class: 'step-title' }, info.name || m.id, ' ', el('code', null, m.id)),
          m.builtIn ? tag('built-in') : tag('custom'),
          info.isStub ? tag('stub', 'tag-stub') : null,
          info.technique ? tag(info.technique) : null,
          info.requiresElevation ? tag('elevation', 'tag-warn') : null,
          m.builtIn ? null : el('button', { class: 'btn btn-small btn-danger', onclick: () => this.remove(m.id) }, 'Remove')),
        m.ok ? el('div', { class: 'step-module' }, info.description || '')
          : el('div', { class: 'step-result err' }, 'Could not load: ' + (m.error || 'unknown error')),
        asArray(info.parameters).length
          ? el('div', { class: 'args' }, 'Parameters: ', asArray(info.parameters).map(p => el('code', { class: 'param-chip', title: p.description || '' }, `${p.name}=${p.default === null ? '' : p.default}`)))
          : null,
        view);
    }));
  },

  async importModule() {
    const id = $('m-id').value.trim();
    const source = $('m-source').value;
    if (!id || !source.trim()) { fill($('m-result'), el('div', { class: 'problems err' }, 'Enter a module id and its code.')); return; }
    if (!window.confirm(`Import module "${id}"? Its code will run on this host as the control-center user whenever a step uses it.`)) return;
    try {
      const r = await api('POST', '/api/modules', { id, source, overwrite: $('m-overwrite').checked });
      fill($('m-result'), el('div', { class: 'ok' }, `Imported "${id}" (${(r.info || {}).name || id}). Add it to a scenario with "Add module step" in the builder.`));
      $('m-source').value = '';
      $('m-id').value = '';
      await this.show();
    } catch (e) {
      fill($('m-result'), el('div', { class: 'problems err' }, e.message));
    }
  },

  async remove(id) {
    if (!window.confirm(`Remove module "${id}"? Scenarios that use it won't load until it is imported again.`)) return;
    try { await api('POST', `/api/modules/${encodeURIComponent(id)}/remove`); await this.show(); }
    catch (e) { showBanner(e.message); }
  },
};

window.Modules = Modules;

window.addEventListener('DOMContentLoaded', () => {
  $('m-import').addEventListener('click', () => Modules.importModule());
  $('m-file').addEventListener('change', async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    $('m-source').value = await f.text();
    if (!$('m-id').value) $('m-id').value = f.name.replace(/\.(ps1|txt)$/i, '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
  });
});
