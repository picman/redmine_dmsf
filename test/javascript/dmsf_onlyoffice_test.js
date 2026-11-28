'use strict';

// Run without a Rails server: node --test test/javascript/dmsf_onlyoffice_test.js
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../assets/javascripts/dmsf_onlyoffice.js'), 'utf8');

// A small DOM boundary keeps these tests focused on event/network behavior.
// innerHTML is forbidden so accidental rendering of server strings fails here.
class Element {
  constructor(tag, owner) {
    this.tagName = tag.toUpperCase();
    this.owner = owner;
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.hidden = false;
    this.disabled = false;
    this.isConnected = false;
    this._text = '';
    owner.elements.push(this);
  }
  get innerHTML() { throw new Error('Do not use innerHTML for editor integration data'); }
  set innerHTML(_) { throw new Error('Do not use innerHTML for editor integration data'); }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get value() {
    if (this._value !== undefined) return this._value;
    if (this.tagName === 'SELECT') {
      const selected = this.children.find(child => child.selected) || this.children[0];
      return selected ? selected.value : '';
    }
    return '';
  }
  set value(value) { this._value = String(value); }
  appendChild(child) { child.parentElement = this; child.isConnected = this.isConnected; this.children.push(child); return child; }
  replaceChildren(...children) { this.children = []; this._text = ''; this._value = undefined; children.forEach(child => this.appendChild(child)); }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  getAttribute(key) { return this.attributes[key]; }
  addEventListener(name, handler, options) {
    (this.listeners[name] ||= []).push({ handler, once: options && options.once });
  }
  emit(name, event = {}) {
    const handlers = (this.listeners[name] || []).slice();
    this.listeners[name] = (this.listeners[name] || []).filter(item => !item.once);
    return Promise.all(handlers.map(item => item.handler(event)));
  }
  querySelectorAll(selector) {
    const children = this.children.flatMap(child => [child, ...child.querySelectorAll('*')]);
    if (selector === '[data-office-action]') return children.filter(child => child.dataset.officeAction);
    return children;
  }
  reportValidity() { return this.querySelectorAll('*').every(child => !child.required || child.value); }
  showModal() { this.open = true; }
  close() { this.open = false; this.emit('close'); }
  remove() { this.isConnected = false; }
}

function environment(overrides = {}) {
  const document = {
    elements: [], hidden: false, listeners: {},
    createElement(tag) { return new Element(tag, this); },
    createTextNode(text) { const item = new Element('#text', this); item.textContent = text; return item; },
    getElementById(id) { return this.elements.find(item => item.id === id); },
    querySelector(selector) { return selector === 'meta[name="csrf-token"]' ? this.csrf : null; },
    addEventListener(name, handler) { this.listeners[name] = handler; }
  };
  document.body = document.createElement('body');
  document.body.isConnected = true;
  document.csrf = document.createElement('meta');
  document.csrf.setAttribute('content', 'test-csrf-token');
  const ids = ['dmsf-onlyoffice', 'dmsf-onlyoffice-notice', 'dmsf-onlyoffice-editor-status',
    'dmsf-onlyoffice-session-status', 'dmsf-onlyoffice-participants', 'dmsf-onlyoffice-review-saved',
    'dmsf-onlyoffice-title', 'dmsf-onlyoffice-version'];
  ids.forEach(id => {
    const element = document.createElement('div');
    element.id = id;
    document.body.appendChild(element);
  });
  const buttons = {};
  ['snapshot', 'publishPdf', 'rename', 'saveCopy', 'fromTemplate', 'history', 'compare'].forEach(action => {
    const button = document.createElement('button');
    button.dataset.officeAction = action;
    document.getElementById('dmsf-onlyoffice').appendChild(button);
    buttons[action] = button;
  });
  const timers = new Map();
  const requests = [];
  const editorCalls = [];
  const constructors = [];
  const storage = new Map(Object.entries(overrides.storage || {}));
  let nextTimerId = 0;
  let currentConfig;
  const win = {
    document, URL,
    location: { href: 'https://redmine.example.test/dmsf/files/1/onlyoffice/edit', origin: 'https://redmine.example.test',
      assign(value) { this.assigned = value; }, reload() { this.reloaded = true; } },
    confirm: overrides.confirm || (() => true),
    addEventListener() {},
    sessionStorage: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    setTimeout(callback, delay) { const key = ++nextTimerId; timers.set(key, { callback, delay }); return key; },
    clearTimeout(key) { timers.delete(key); },
    async fetch(url, init) {
      const item = { url: new URL(url), init, data: init.body ? JSON.parse(init.body) : null };
      requests.push(item);
      const response = overrides.respond ? await overrides.respond(item) : {};
      return { ok: (response.status || 200) < 400, json: async () => response.body || {} };
    },
    DocsAPI: {
      DocEditor: function (id, config) {
        constructors.push(id);
        currentConfig = config;
        ['refreshHistory', 'setHistoryData', 'setRequestedDocument', 'refreshFile', 'setUsers', 'setActionLink', 'downloadAs'].forEach(method => {
          this[method] = value => editorCalls.push({ method, value });
        });
      }
    }
  };
  vm.runInNewContext(source, { window: win });
  const config = {
    type: overrides.editorType || 'desktop',
    document: { key: 'shared-editing-key', fileType: 'docx', title: 'Example.docx' },
    editorConfig: { user: { id: '2' } }
  };
  const options = {
    fileId: 1, folderId: 3, revisionId: 10, filename: 'Example.docx', mode: 'edit', key: config.document.key,
    urls: overrides.urls || {}, canEdit: true, canCompare: true,
    messages: { editorSynced: 'Changes have reached ONLYOFFICE.', sessionSaved: 'Final revision saved in DMSF',
      sessionSnapshot: 'Recovery snapshot stored in DMSF', sessionActive: 'Editing session active',
      snapshotRequested: 'Waiting for the requested snapshot to reach DMSF',
      requestFailed: 'Request failed', completed: 'Completed', participants: 'Connected users',
      sessionParticipants: 'Session participants' }
  };
  const integration = win.DmsfOnlyoffice.mount(config, options);
  // The Document Server asks for the user list before onDocumentReady fires.
  // Tests covering that window pass ready: false and fire the event themselves.
  if (overrides.ready !== false) currentConfig.events.onDocumentReady();
  async function settle() { await new Promise(resolve => setImmediate(resolve)); }
  async function timer(delay) {
    const item = [...timers.entries()].find(([, value]) => value.delay === delay);
    assert.ok(item, 'Expected a timer with delay ' + delay);
    timers.delete(item[0]);
    item[1].callback();
    await settle();
  }
  return { win, document, requests, editorCalls, constructors, timers, storage, integration,
    events: currentConfig.events, buttons, settle, timer, config };
}

test('history and restore events are absent when their authorized URLs are absent', () => {
  const env = environment();
  assert.equal(env.events.onRequestHistory, undefined);
  assert.equal(env.events.onRequestHistoryData, undefined);
  assert.equal(env.events.onRequestRestore, undefined);
  assert.equal(env.events.onRequestRename, undefined);
});

test('history data keeps the server signature and chooses the requested retained revision', async () => {
  const env = environment({ urls: { history: '/history', historyData: '/history/data?revision_id=__revision__' },
    respond: item => ({ body: { version: Number(item.url.searchParams.get('revision_id')), token: 'signed-history-token', url: 'https://redmine.example.test/signed-document' } }) });
  await env.events.onRequestHistoryData({ data: 27 });
  assert.equal(env.requests[0].url.searchParams.get('revision_id'), '27');
  assert.equal(env.requests[0].init.credentials, 'same-origin');
  assert.equal(env.editorCalls[0].method, 'setHistoryData');
  assert.equal(env.editorCalls[0].value.token, 'signed-history-token');
  assert.equal(env.editorCalls[0].value.version, 27);
});

test('ONLYOFFICE synchronization never claims a final DMSF save', () => {
  const env = environment();
  env.events.onDocumentStateChange({ data: false });
  assert.equal(env.document.getElementById('dmsf-onlyoffice-editor-status').textContent, 'Changes have reached ONLYOFFICE.');
  assert.equal(env.document.getElementById('dmsf-onlyoffice-session-status').textContent, '');
});

test('a snapshot preserves the common editing key and waits for durable server state', async () => {
  let sessionState = 'active';
  const env = environment({ urls: { session: '/session', forcesave: '/forcesave', rename: '/rename' },
    respond: item => {
      if (item.url.pathname === '/session') return { body: { state: sessionState, last_callback_at: sessionState === 'active' ? '2026-01-01T12:00:00Z' : '2026-01-01T12:01:00Z', participants: ['2', '7'] } };
      if (item.url.pathname === '/forcesave') { sessionState = 'snapshot'; return { body: { error: 0, request_id: 'request-1' } }; }
      return { body: { title: 'Renamed.docx' } };
    } });
  await env.settle();
  await env.buttons.snapshot.emit('click');
  await env.events.onRequestRename({ data: 'Renamed.docx' });
  const writes = env.requests.filter(item => item.init.method === 'POST');
  assert.ok(writes.every(item => item.data.key === 'shared-editing-key'));
  assert.ok(writes.every(item => item.init.headers['X-CSRF-Token'] === 'test-csrf-token'));
  assert.equal(env.constructors.length, 1);
  assert.equal(env.editorCalls.filter(item => item.method === 'refreshFile').length, 0);
  assert.match(env.document.getElementById('dmsf-onlyoffice-session-status').textContent, /Recovery snapshot stored/);
  assert.match(env.document.getElementById('dmsf-onlyoffice-participants').textContent, /Session participants: 2/);
});

test('a previous snapshot or another author callback cannot confirm the newly requested snapshot', async () => {
  let receipts = [{ id: 3, kind: 'snapshot', state: 'pending', request_ids: ['previous-request'] }];
  let lastCallback = '2026-01-01T12:00:00Z';
  const env = environment({ urls: { session: '/session', forcesave: '/forcesave' },
    respond: item => {
      if (item.url.pathname === '/forcesave') {
        lastCallback = '2026-01-01T12:01:00Z';
        return { body: { error: 0, request_id: 'new-request' } };
      }
      return { body: { state: 'snapshot', last_callback_at: lastCallback, receipts } };
    } });
  await env.settle();
  await env.buttons.snapshot.emit('click');
  const notice = env.document.getElementById('dmsf-onlyoffice-notice');
  assert.equal(notice.textContent, 'Waiting for the requested snapshot to reach DMSF');
  receipts.push({ id: 4, kind: 'snapshot', state: 'pending', request_ids: ['other-author-request'] });
  lastCallback = '2026-01-01T12:02:00Z';
  await env.integration.pollSession();
  assert.equal(notice.textContent, 'Waiting for the requested snapshot to reach DMSF');
  // The same bytes can be deduplicated into an older stored recovery. The
  // request receipt, not timestamps or a fresh row, confirms acquisition.
  receipts[0].request_ids.push('new-request');
  await env.integration.pollSession();
  assert.equal(notice.textContent, 'Recovery snapshot stored in DMSF');
});

test('only the explicit refresh event changes the key and expected head while preserving editor type', async () => {
  const env = environment({ editorType: 'mobile', urls: { refresh: '/refresh', rename: '/rename' },
    respond: item => item.url.pathname === '/refresh' ? { body: {
      config: { document: { key: 'next-shared-key', title: 'New head.docx' } }, revision_id: 42, version: '2.1'
    } } : { body: { title: 'Renamed.docx' } } });
  await env.events.onRequestRefreshFile();
  await env.events.onRequestRename({ data: 'Renamed.docx' });
  const write = env.requests.find(item => item.url.pathname === '/rename');
  assert.equal(env.requests.find(item => item.url.pathname === '/refresh').url.searchParams.get('editor_type'), 'mobile');
  assert.equal(write.data.key, 'next-shared-key');
  assert.equal(write.data.expected_revision_id, 42);
  assert.equal(env.document.getElementById('dmsf-onlyoffice-version').textContent, '2.1');
  assert.equal(env.editorCalls.filter(item => item.method === 'refreshFile').length, 1);
});

test('a late recovery conflict warns users while retaining the separately confirmed final revision', async () => {
  let lastError = null;
  const env = environment({ urls: { session: '/session', recovery: '/recovery' }, respond: () => ({ body: {
    state: 'saved', saved_revision_id: 30, last_error: lastError
  } }) });
  await env.settle();
  assert.equal(env.document.getElementById('dmsf-onlyoffice-review-saved').hidden, false);
  lastError = 'A later working copy needs recovery review';
  await env.integration.pollSession();
  const notice = env.document.getElementById('dmsf-onlyoffice-notice');
  assert.match(env.document.getElementById('dmsf-onlyoffice-session-status').textContent, /Final revision saved/);
  assert.match(notice.textContent, /later working copy/);
  assert.equal(notice.dataset.error, 'true');
  assert.equal(env.document.getElementById('dmsf-onlyoffice-review-saved').hidden, true);
  assert.equal(notice.children.find(child => child.tagName === 'A').href, 'https://redmine.example.test/recovery');
});

test('a stale session response cannot overwrite the explicitly refreshed session', async () => {
  let reply;
  const delayed = new Promise(resolve => { reply = resolve; });
  const env = environment({ urls: { session: '/session', refresh: '/refresh', rename: '/rename' }, respond: item => {
    if (item.url.pathname === '/session') return delayed;
    if (item.url.pathname === '/refresh') return { body: {
      config: { document: { key: 'next-shared-key', title: 'Refreshed.docx' } }, revision_id: 42
    } };
    return { body: { title: 'Renamed.docx' } };
  } });
  await env.events.onRequestRefreshFile();
  reply({ body: { state: 'saved', saved_revision_id: 500 } });
  await env.settle();
  await env.events.onRequestRename({ data: 'Renamed.docx' });
  assert.equal(env.requests.find(item => item.url.pathname === '/rename').data.expected_revision_id, 42);
  assert.equal(env.document.getElementById('dmsf-onlyoffice-session-status').textContent, '');
});

test('restore is an explicit CSRF protected new-revision request with the expected head', async () => {
  const env = environment({ urls: { history: '/history', historyData: '/history/data', restore: '/restore' },
    respond: item => item.url.pathname === '/restore' ?
      { body: { revision_id: 30, url: '/dmsf/files/1' } } : { body: { currentVersion: 30, history: [] } } });
  await env.events.onRequestRestore({ data: { version: 4 } });
  const write = env.requests.find(item => item.url.pathname === '/restore');
  assert.equal(write.init.method, 'POST');
  assert.equal(write.data.revision_id, 4);
  assert.equal(write.data.expected_revision_id, 10);
  assert.equal(write.init.headers['X-CSRF-Token'], 'test-csrf-token');
  assert.equal(env.editorCalls.filter(item => item.method === 'refreshHistory').length, 1);
  assert.equal(env.win.location.reloaded, undefined);
});

test('a conflicting restore renders a readable error and never refreshes the history as a success', async () => {
  const env = environment({ urls: { history: '/history', historyData: '/history/data', restore: '/restore' },
    respond: () => ({ status: 409, body: { error: '<img src=x onerror=alert(1)> conflict' } }) });
  await env.events.onRequestRestore({ data: { version: 4 } });
  const notice = env.document.getElementById('dmsf-onlyoffice-notice');
  assert.equal(notice.dataset.error, 'true');
  assert.match(notice.textContent, /<img src=x/);
  assert.equal(env.document.elements.filter(item => item.tagName === 'IMG').length, 0);
  assert.equal(env.editorCalls.length, 0);
});

test('PDF publication polls the existing operation and persists it for interrupted-page recovery', async () => {
  let count = 0;
  const env = environment({ urls: { publishPdf: '/pdf' }, respond: () => {
    count += 1;
    return count === 1 ? { status: 202, body: { pending: true, operation_id: 91 } } : { body: { url: '/dmsf/files/91' } };
  } });
  const clicked = env.buttons.publishPdf.emit('click');
  await env.settle();
  const stored = JSON.parse(env.storage.get('dmsf-onlyoffice-operation-1-2'));
  assert.equal(stored.operation_id, 91);
  await env.timer(2000);
  await clicked;
  assert.equal(env.requests[0].data.revision_id, 10);
  assert.equal(env.requests[1].data.operation_id, 91);
  assert.equal(env.storage.has('dmsf-onlyoffice-operation-1-2'), false);
  assert.match(env.document.getElementById('dmsf-onlyoffice-notice').textContent, /Completed/);
});

test('save-copy keeps the current editor open and delegates the remote result download to the backend', async () => {
  const env = environment({ urls: { saveAs: '/copy', destinations: '/destinations' }, respond: item =>
    item.url.pathname === '/destinations' ? { body: { folders: [{ id: 3, name: 'Reports' }] } } :
      { body: { url: '/dmsf/files/12', file_id: 12 } } });
  const saving = env.events.onRequestSaveAs({ data: { title: 'Copy.docx', fileType: 'docx', url: 'https://office.example.test/cache/copy.docx' } });
  await env.settle();
  env.document.getElementById('dmsf-onlyoffice-field-title').value = 'New copy.docx';
  const form = env.document.elements.find(item => item.tagName === 'FORM');
  await form.emit('submit', { preventDefault() {} });
  await saving;
  const write = env.requests.find(item => item.url.pathname === '/copy');
  assert.equal(write.data.title, 'New copy.docx');
  assert.equal(write.data.folder_id, '3');
  assert.equal(write.data.file_type, 'docx');
  assert.equal(write.data.url, 'https://office.example.test/cache/copy.docx');
  assert.ok(env.requests.every(item => item.url.origin === 'https://redmine.example.test'));
  assert.equal(env.win.location.assigned, undefined);
});

test('notifications require explicit confirmation and keep action-link context', async () => {
  let permitted = false;
  const env = environment({ urls: { notify: '/notify' }, confirm: () => permitted });
  const event = { data: { message: 'Please review', emails: ['dmsf-user-7@redmine.invalid'], actionLink: { action: { type: 'comment', data: 'comment-1' } } } };
  await env.events.onRequestSendNotify(event);
  assert.equal(env.requests.length, 0);
  permitted = true;
  await env.events.onRequestSendNotify(event);
  assert.equal(env.requests[0].data.action_link.action.data, 'comment-1');
  assert.equal(env.requests[0].init.headers['X-CSRF-Token'], 'test-csrf-token');
});

test('browser operations reject an endpoint outside the Redmine origin', async () => {
  const env = environment({ urls: { rename: 'https://other.example.test/rename' } });
  await env.events.onRequestRename({ data: 'Name.docx' });
  assert.equal(env.requests.length, 0);
  assert.equal(env.document.getElementById('dmsf-onlyoffice-notice').dataset.error, 'true');
});

test('a user list requested before the editor is ready is applied when the document becomes ready', async () => {
  const env = environment({ ready: false, urls: { users: '/users' },
    respond: () => ({ body: { users: [{ id: '7', name: 'Dmsf User' }] } }) });
  await env.events.onRequestUsers({ data: { c: 'shared-editing-key' } });
  assert.equal(env.requests.length, 1);
  assert.equal(env.requests[0].url.pathname, '/users');
  assert.equal(env.requests[0].url.searchParams.get('c'), 'shared-editing-key');
  // The editor is not ready yet: answering now would throw and lose the list.
  assert.equal(env.editorCalls.filter(item => item.method === 'setUsers').length, 0);
  env.events.onDocumentReady();
  const applied = env.editorCalls.filter(item => item.method === 'setUsers');
  assert.equal(applied.length, 1);
  assert.equal(applied[0].value.c, 'shared-editing-key');
  assert.equal(applied[0].value.users.length, 1);
  assert.equal(applied[0].value.users[0].id, '7');
  assert.equal(env.document.getElementById('dmsf-onlyoffice-notice').dataset.error, undefined);
});

test('a failed user list request answers the document server with an empty list and no uncaught error', async () => {
  const env = environment({ ready: false, urls: { users: '/users' },
    respond: () => ({ status: 500, body: { error: 'users unavailable' } }) });
  await env.events.onRequestUsers({ data: { c: 'shared-editing-key' } });
  const notice = env.document.getElementById('dmsf-onlyoffice-notice');
  assert.equal(notice.dataset.error, 'true');
  assert.match(notice.textContent, /users unavailable/);
  env.events.onDocumentReady();
  const applied = env.editorCalls.filter(item => item.method === 'setUsers');
  assert.equal(applied.length, 1);
  assert.equal(applied[0].value.c, 'shared-editing-key');
  assert.equal(applied[0].value.users.length, 0);
});

test('user lists requested for two contexts before the editor is ready are all applied', async () => {
  const pending = {};
  const gate = key => {
    if (!pending[key]) {
      let resolve;
      const promise = new Promise(done => { resolve = done; });
      pending[key] = { promise, resolve };
    }
    return pending[key];
  };
  const env = environment({ ready: false, urls: { users: '/users' },
    respond: item => gate(item.url.searchParams.get('c')).promise });
  const first = env.events.onRequestUsers({ data: { c: 'context-one' } });
  const second = env.events.onRequestUsers({ data: { c: 'context-two' } });
  gate('context-one').resolve({ body: { users: [{ id: '1', name: 'User One' }] } });
  gate('context-two').resolve({ body: { users: [{ id: '2', name: 'User Two' }] } });
  await Promise.all([first, second]);
  // Both answers are buffered: the second one must not replace the first.
  assert.equal(env.editorCalls.filter(item => item.method === 'setUsers').length, 0);
  env.events.onDocumentReady();
  const applied = env.editorCalls.filter(item => item.method === 'setUsers');
  assert.equal(applied.length, 2);
  assert.deepEqual(applied.map(item => item.value.c).sort(), ['context-one', 'context-two']);
  const byContext = {};
  applied.forEach(item => { byContext[item.value.c] = item.value.users.map(user => user.id); });
  assert.deepEqual(byContext, { 'context-one': ['1'], 'context-two': ['2'] });
});

