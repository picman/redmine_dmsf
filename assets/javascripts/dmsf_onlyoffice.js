/* global DocsAPI */
(function (global) {
  'use strict';

  function mount(configuration, options) {
    const doc = global.document;
    const root = doc.getElementById('dmsf-onlyoffice');
    const urls = options.urls || {};
    const messages = options.messages || {};
    const state = {
      key: options.key,
      expectedRevisionId: options.revisionId,
      filename: options.filename,
      editor: null,
      editorReady: false,
      busy: false,
      disposed: false,
      dirty: false,
      pollTimer: null,
      polling: false,
      lastError: null,
      snapshotRequestId: null,
      activeDialog: null,
      copyRequest: null
    };
    const notice = doc.getElementById('dmsf-onlyoffice-notice');
    const editorStatus = doc.getElementById('dmsf-onlyoffice-editor-status');
    const sessionStatus = doc.getElementById('dmsf-onlyoffice-session-status');
    const participants = doc.getElementById('dmsf-onlyoffice-participants');
    const reviewSaved = doc.getElementById('dmsf-onlyoffice-review-saved');
    const sessionContainer = sessionStatus && sessionStatus.parentElement;
    const storageKey = 'dmsf-onlyoffice-operation-' + options.fileId + '-' +
      String((configuration.editorConfig && configuration.editorConfig.user && configuration.editorConfig.user.id) || '');

    function message(name) { return messages[name] || name; }

    function localUrl(value) {
      const parsed = new global.URL(value, global.location.href);
      if (parsed.origin !== global.location.origin) throw new Error(message('requestFailed'));
      return parsed;
    }

    async function request(url, method, values) {
      const parsed = localUrl(url);
      const headers = { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
      const init = { method: method || 'GET', credentials: 'same-origin', headers: headers, cache: 'no-store' };
      if (init.method === 'GET') {
        Object.keys(values || {}).forEach(function (key) {
          if (values[key] !== undefined && values[key] !== null) parsed.searchParams.set(key, values[key]);
        });
      } else {
        headers['Content-Type'] = 'application/json';
        const csrf = doc.querySelector('meta[name="csrf-token"]');
        if (csrf) headers['X-CSRF-Token'] = csrf.getAttribute('content');
        init.body = JSON.stringify(values || {});
      }
      const response = await global.fetch(parsed.toString(), init);
      let body;
      try {
        body = await response.json();
      } catch (_) {
        throw new Error(message('requestFailed'));
      }
      if (!response.ok || (typeof body.error === 'string' && body.error)) {
        throw new Error(typeof body.error === 'string' ? body.error.slice(0, 500) : message('requestFailed'));
      }
      return body;
    }

    function context(values) {
      return Object.assign({ key: state.key, expected_revision_id: state.expectedRevisionId }, values || {});
    }

    function showNotice(text, error, resultUrl) {
      if (!notice) return;
      notice.replaceChildren();
      notice.appendChild(doc.createTextNode(String(text || message('completed'))));
      notice.hidden = false;
      notice.dataset.error = error ? 'true' : 'false';
      notice.setAttribute('role', error ? 'alert' : 'status');
      if (resultUrl) {
        try {
          const link = doc.createElement('a');
          link.href = localUrl(resultUrl).toString();
          link.textContent = resultUrl === urls.recovery ? message('recover') : message('openDocument');
          link.target = '_blank';
          link.rel = 'noopener noreferrer';
          notice.appendChild(link);
        } catch (_) { /* Keep the success text without an untrusted navigation target. */ }
      }
    }

    function showError(error) {
      showNotice(error && error.message ? error.message : message('requestFailed'), true);
    }

    function setBusy(busy) {
      state.busy = busy;
      if (root) root.querySelectorAll('[data-office-action]').forEach(function (button) { button.disabled = busy; });
    }

    async function run(action) {
      if (state.busy || state.disposed) return;
      setBusy(true);
      try {
        await action();
      } catch (error) {
        showError(error);
      } finally {
        if (!state.disposed) setBusy(false);
      }
    }

    function editor() {
      if (!state.editor || !state.editorReady) throw new Error(message('editorUnavailable'));
      return state.editor;
    }

    function replaceOptions(select, values, selected) {
      select.replaceChildren();
      values.forEach(function (value) {
        const option = doc.createElement('option');
        option.value = value.value === null || value.value === undefined ? '' : String(value.value);
        option.textContent = String(value.label);
        if (String(selected) === option.value) option.selected = true;
        select.appendChild(option);
      });
    }

    function formDialog(title, fields, submitLabel) {
      const dialog = doc.createElement('dialog');
      dialog.className = 'dmsf-onlyoffice-dialog';
      const form = doc.createElement('form');
      form.method = 'dialog';
      const heading = doc.createElement('h3');
      heading.textContent = title;
      heading.id = 'dmsf-onlyoffice-dialog-heading';
      dialog.setAttribute('aria-labelledby', heading.id);
      form.appendChild(heading);
      const controls = {};
      fields.forEach(function (field) {
        const label = doc.createElement('label');
        const input = doc.createElement(field.options ? 'select' : 'input');
        input.id = 'dmsf-onlyoffice-field-' + field.name;
        input.name = field.name;
        input.required = field.required === true;
        label.htmlFor = input.id;
        label.textContent = field.label;
        form.appendChild(label);
        if (field.options) {
          replaceOptions(input, field.options, field.value);
        } else {
          input.type = field.type || 'text';
          input.value = field.value || '';
          input.maxLength = field.maxLength || 255;
          if (input.type === 'number') input.min = '1';
        }
        form.appendChild(input);
        controls[field.name] = input;
        if (field.help) {
          const help = doc.createElement('p');
          help.className = 'dmsf-onlyoffice-help';
          help.textContent = field.help;
          form.appendChild(help);
        }
      });
      const error = doc.createElement('p');
      error.className = 'dmsf-onlyoffice-dialog-error';
      error.setAttribute('role', 'alert');
      form.appendChild(error);
      const actions = doc.createElement('div');
      actions.className = 'dmsf-onlyoffice-dialog-actions';
      const cancel = doc.createElement('button');
      cancel.type = 'button';
      cancel.textContent = message('cancel');
      const submit = doc.createElement('button');
      submit.type = 'submit';
      submit.textContent = submitLabel || message('save');
      actions.appendChild(cancel);
      actions.appendChild(submit);
      form.appendChild(actions);
      dialog.appendChild(form);
      doc.body.appendChild(dialog);
      let answer = null;
      const result = new Promise(function (resolve) {
        dialog.addEventListener('close', function () {
          state.activeDialog = null;
          dialog.remove();
          resolve(answer);
        }, { once: true });
        cancel.addEventListener('click', function () { dialog.close(); });
        form.addEventListener('submit', function (event) {
          event.preventDefault();
          if (submit.disabled || !form.reportValidity()) return;
          answer = {};
          Object.keys(controls).forEach(function (key) { answer[key] = controls[key].value; });
          dialog.close();
        });
      });
      state.activeDialog = dialog;
      dialog.showModal();
      return { dialog: dialog, controls: controls, submit: submit, error: error, result: result };
    }

    function revisionLabel(revision) {
      const date = new Date(revision.created);
      const stamp = Number.isNaN(date.getTime()) ? '' : date.toLocaleString();
      return String(revision.version) + (stamp ? ' · ' + stamp : '') + ' · ' + revision.name;
    }

    async function openComparison(operation) {
      if (!urls.compare || !options.canCompare) return;
      const initial = await request(urls.compare, 'GET', { c: operation });
      const picker = formDialog(message('compare'), [
        { name: 'search', label: message('search'), help: message('searchHint') },
        { name: 'file', label: message('document'), required: true,
          options: initial.files.map(function (file) { return { value: file.id, label: file.name }; }),
          value: initial.selected_file_id },
        { name: 'revision', label: message('version'), required: true, options: [] }
      ], message('compare'));
      let revisions = initial.revisions;
      let sequence = 0;
      let searchTimer;
      function updateVersions(data) {
        revisions = data.revisions;
        replaceOptions(picker.controls.revision, revisions.map(function (revision) {
          return { value: revision.id, label: revisionLabel(revision) };
        }));
        picker.submit.disabled = revisions.length === 0;
        picker.error.textContent = revisions.length ? (data.truncated ? message('searchMore') : '') : message('noVersions');
      }
      async function load(searching) {
        const current = ++sequence;
        picker.submit.disabled = true;
        try {
          const values = { c: operation, q: picker.controls.search.value };
          if (!searching) values.file_id = picker.controls.file.value;
          const data = await request(urls.compare, 'GET', values);
          if (current !== sequence || !picker.dialog.isConnected) return;
          replaceOptions(picker.controls.file, data.files.map(function (file) {
            return { value: file.id, label: file.name };
          }), data.selected_file_id);
          updateVersions(data);
        } catch (error) {
          if (current === sequence) picker.error.textContent = error.message;
        }
      }
      updateVersions(initial);
      picker.controls.file.addEventListener('change', function () { load(false); });
      picker.controls.search.addEventListener('input', function () {
        global.clearTimeout(searchTimer);
        searchTimer = global.setTimeout(function () { load(true); }, 300);
      });
      const answer = await picker.result;
      global.clearTimeout(searchTimer);
      sequence += 1;
      if (!answer) return;
      const revision = revisions.find(function (item) { return String(item.id) === answer.revision; });
      if (revision) editor().setRequestedDocument(revision.request);
    }

    async function requestHistory() {
      try {
        const history = await request(urls.history, 'GET');
        editor().refreshHistory(history);
      } catch (error) {
        if (state.editor) state.editor.refreshHistory({ error: error.message });
        showError(error);
      }
    }

    async function requestHistoryData(event) {
      const version = typeof event.data === 'object' ? event.data.version : event.data;
      const target = urls.historyData.replace('__revision__', encodeURIComponent(version));
      try {
        const payload = await request(target, 'GET', { revision_id: version });
        editor().setHistoryData(payload);
      } catch (error) {
        if (state.editor) state.editor.setHistoryData({ version: version, error: error.message });
        showError(error);
      }
    }

    async function restore(event) {
      if (!global.confirm(message('confirmRestore'))) return;
      showNotice(message('restoring'));
      const data = await request(urls.restore, 'POST', context({ revision_id: event.data.version }));
      state.expectedRevisionId = data.revision_id;
      showNotice(message('restored'), false, data.url);
      await requestHistory();
    }

    async function snapshot() {
      const data = await request(urls.forcesave, 'POST', context());
      if (Number(data.error) === 4) {
        state.snapshotRequestId = null;
        showNotice(message('noChanges'));
      } else {
        state.snapshotRequestId = typeof data.request_id === 'string' ? data.request_id : null;
        showNotice(message('snapshotRequested'));
      }
      await pollSession();
    }

    function applySession(data) {
      const names = {
        active: 'sessionActive', snapshot: 'sessionSnapshot', saved: 'sessionSaved',
        recovery: 'sessionRecovery', error: 'sessionError', closed: 'sessionClosed', submitted: 'sessionSubmitted'
      };
      if (sessionStatus) {
        let text = message(names[data.state] || 'sessionActive');
        const time = new Date(data.last_callback_at);
        if (data.last_callback_at && !Number.isNaN(time.getTime())) {
          text += ' · ' + message('lastReceived') + ': ' + time.toLocaleString();
        }
        sessionStatus.textContent = text;
      }
      if (sessionContainer) sessionContainer.dataset.state = data.state;
      if (participants) {
        if (Array.isArray(data.connected_users) && data.last_presence_at) {
          participants.textContent = message('participants') + ': ' + data.connected_users.length;
        } else {
          participants.textContent = Array.isArray(data.participants) && data.participants.length ?
            message('sessionParticipants') + ': ' + data.participants.length : '';
        }
      }
      if (reviewSaved) reviewSaved.hidden = !(data.state === 'saved' && data.saved_revision_id && !state.dirty && !data.last_error);
      if (data.state === 'saved' && Number(data.saved_revision_id) > Number(state.expectedRevisionId)) {
        state.expectedRevisionId = data.saved_revision_id;
      }
      if (data.last_error) {
        if (state.lastError !== data.last_error) showNotice(String(data.last_error).slice(0, 500), true, urls.recovery);
      } else if (state.snapshotRequestId) {
        const receipt = Array.isArray(data.receipts) && data.receipts.some(function (item) {
          return item.kind === 'snapshot' && ['pending', 'imported'].indexOf(item.state) >= 0 &&
            Array.isArray(item.request_ids) && item.request_ids.indexOf(state.snapshotRequestId) >= 0;
        });
        if (receipt) {
          showNotice(message('sessionSnapshot'));
          state.snapshotRequestId = null;
        } else if (data.state === 'saved' && data.saved_revision_id) {
          // A final revision is independently useful, but an older snapshot or
          // another author's callback must never confirm this snapshot request.
          showNotice(message('sessionSaved'));
          state.snapshotRequestId = null;
        }
      }
      state.lastError = data.last_error;
    }

    async function pollSession() {
      if (!urls.session || state.disposed || state.polling) return;
      state.polling = true;
      const requestedKey = state.key;
      try {
        const data = await request(urls.session, 'GET', { key: requestedKey });
        if (!state.disposed && state.key === requestedKey) applySession(data);
      } catch (error) {
        if (!state.disposed && state.key === requestedKey && sessionStatus) sessionStatus.textContent = message('requestFailed');
      } finally {
        state.polling = false;
      }
    }

    function schedulePoll() {
      if (!urls.session || state.disposed) return;
      state.pollTimer = global.setTimeout(async function () {
        if (!doc.hidden) await pollSession();
        schedulePoll();
      }, options.pollInterval || 5000);
    }

    async function rename(title) {
      let newTitle = title;
      if (newTitle === undefined) {
        const form = formDialog(message('rename'), [
          { name: 'title', label: message('title'), value: state.filename, required: true }
        ]);
        const answer = await form.result;
        if (!answer) return;
        newTitle = answer.title;
      }
      const data = await request(urls.rename, 'POST', context({ title: newTitle }));
      updateTitle(data.title || newTitle);
      showNotice(data.warning || message('completed'), Boolean(data.warning));
    }

    function updateTitle(title) {
      state.filename = String(title);
      const heading = doc.getElementById('dmsf-onlyoffice-title');
      if (heading) heading.textContent = state.filename;
    }

    async function destinationFields() {
      if (!urls.destinations) return [];
      const data = await request(urls.destinations, 'GET');
      return [{ name: 'folder_id', label: message('folder'),
        value: options.folderId === null || options.folderId === undefined ? '' : options.folderId,
        options: data.folders.map(function (folder) { return { value: folder.id, label: folder.name }; }) }];
    }

    async function saveCopy(data) {
      const fields = [{ name: 'title', label: message('title'), value: data.title || state.filename, required: true }];
      fields.push.apply(fields, await destinationFields());
      const form = formDialog(message('saveCopy'), fields);
      const answer = await form.result;
      if (!answer) return;
      const values = Object.assign(answer, { url: data.url, file_type: data.fileType });
      const result = await request(urls.saveAs, 'POST', context(values));
      showNotice(message('completed'), false, result.url);
    }

    async function downloadCopy() {
      const data = await new Promise(function (resolve, reject) {
        const timer = global.setTimeout(function () {
          state.copyRequest = null;
          reject(new Error(message('requestFailed')));
        }, 30000);
        state.copyRequest = { resolve: resolve, reject: reject, timer: timer };
        try {
          editor().downloadAs();
        } catch (error) {
          global.clearTimeout(timer);
          state.copyRequest = null;
          reject(error);
        }
      });
      await saveCopy(data);
    }

    function persistOperation(value) {
      try {
        if (value) global.sessionStorage.setItem(storageKey, JSON.stringify(value));
        else global.sessionStorage.removeItem(storageKey);
      } catch (_) { /* The operation can still finish when browser storage is unavailable. */ }
    }

    async function finishOperation(kind, result) {
      let data = result;
      let attempts = 0;
      const endpoint = kind === 'pdf' ? urls.publishPdf : urls.createFromTemplate;
      while (data.pending && data.operation_id && attempts < 60 && !state.disposed) {
        persistOperation({ kind: kind, operation_id: data.operation_id });
        showNotice(message('pending'));
        await new Promise(function (resolve) { global.setTimeout(resolve, 2000); });
        if (state.disposed) return;
        data = await request(endpoint, 'POST', context({ operation_id: data.operation_id }));
        attempts += 1;
      }
      if (state.disposed) return;
      if (data.pending) {
        showNotice(message('pending'));
        const retry = doc.createElement('button');
        retry.type = 'button';
        retry.textContent = message('retry');
        retry.addEventListener('click', function () { run(function () { return finishOperation(kind, data); }); });
        notice.appendChild(retry);
      } else {
        persistOperation(null);
        showNotice(message('completed'), false, data.url);
      }
    }

    async function createFromTemplate() {
      const data = await request(urls.templates, 'GET');
      if (!data.templates.length) { showNotice(message('noTemplates')); return; }
      const fields = [
        { name: 'template_id', label: message('template'), required: true,
          options: data.templates.map(function (template) { return { value: template.id, label: template.name }; }) },
        { name: 'title', label: message('title'), required: true },
        { name: 'issue_id', label: message('issue'), type: 'number' }
      ];
      fields.push.apply(fields, await destinationFields());
      const form = formDialog(message('fromTemplate'), fields, message('create'));
      const answer = await form.result;
      if (!answer) return;
      const result = await request(urls.createFromTemplate, 'POST', context(answer));
      await finishOperation('template', result);
    }

    async function refresh() {
      const config = await request(urls.refresh, 'GET', {
        key: state.key, mode: options.mode, editor_type: configuration.type
      });
      const next = config.config || config;
      // Only the editor's explicit refresh event may replace the editing key.
      // Snapshot requests and session polling never split collaborative users.
      editor().refreshFile(next);
      state.key = next.document.key;
      if (config.revision_id) state.expectedRevisionId = config.revision_id;
      if (next.document.title) updateTitle(next.document.title);
      const version = doc.getElementById('dmsf-onlyoffice-version');
      if (version && config.version) version.textContent = String(config.version);
      state.snapshotRequestId = null;
      await pollSession();
    }

    const events = Object.assign({}, configuration.events || {});
    events.onDocumentReady = function () {
      state.editorReady = true;
      if (editorStatus) editorStatus.textContent = message('editorSynced');
    };
    events.onDocumentStateChange = function (event) {
      state.dirty = event.data === true;
      if (editorStatus) editorStatus.textContent = message(state.dirty ? 'localChanges' : 'editorSynced');
      if (state.dirty && reviewSaved) reviewSaved.hidden = true;
    };
    events.onError = function (event) {
      const description = event && event.data && event.data.errorDescription;
      if (state.copyRequest) {
        global.clearTimeout(state.copyRequest.timer);
        state.copyRequest.reject(new Error(description || message('requestFailed')));
        state.copyRequest = null;
      }
      showNotice(description || message('editorUnavailable'), true);
    };
    events.onWarning = function (event) {
      const description = event && event.data && event.data.warningDescription;
      if (description) showNotice(description, true);
    };
    if (urls.history && urls.historyData) {
      events.onRequestHistory = requestHistory;
      events.onRequestHistoryData = requestHistoryData;
      events.onRequestHistoryClose = function () { global.location.reload(); };
      if (urls.restore) events.onRequestRestore = function (event) { return run(function () { return restore(event); }); };
    }
    if (urls.compare && options.canCompare) {
      events.onRequestSelectDocument = function (event) {
        const operation = event.data && event.data.c;
        if (['compare', 'combine', 'insert-text'].indexOf(operation) < 0) return;
        return run(function () { return openComparison(operation); });
      };
    }
    if (urls.rename) events.onRequestRename = function (event) { return run(function () { return rename(event.data); }); };
    if (urls.saveAs) {
      events.onRequestSaveAs = function (event) { return run(function () { return saveCopy(event.data); }); };
      events.onDownloadAs = function (event) {
        if (!state.copyRequest) return;
        global.clearTimeout(state.copyRequest.timer);
        state.copyRequest.resolve(Object.assign({ title: state.filename }, event.data));
        state.copyRequest = null;
      };
    }
    events.onMetaChange = function (event) {
      if (event.data && event.data.title) updateTitle(event.data.title);
    };
    if (urls.refresh) events.onRequestRefreshFile = function () { return run(refresh); };
    if (urls.back) events.onRequestClose = function () { global.location.assign(localUrl(urls.back).toString()); };
    if (urls.users) {
      events.onRequestUsers = async function (event) {
        try {
          const data = await request(urls.users, 'GET', { c: event.data.c });
          editor().setUsers({ c: event.data.c, users: data.users });
        } catch (error) {
          editor().setUsers({ c: event.data.c, users: [] });
          showError(error);
        }
      };
    }
    if (urls.actionLink) {
      events.onMakeActionLink = async function (event) {
        try {
          const data = await request(urls.actionLink, 'POST', { action_link: event.data });
          editor().setActionLink(data.url);
        } catch (error) { showError(error); }
      };
    }
    if (urls.notify) {
      events.onRequestSendNotify = function (event) {
        if (!global.confirm(message('confirmNotify') + '\n\n' + String(event.data.message || '').slice(0, 4000))) return;
        return run(async function () {
          await request(urls.notify, 'POST', {
            emails: event.data.emails, message: event.data.message, action_link: event.data.actionLink
          });
          showNotice(message('completed'));
        });
      };
    }
    if (options.mode === 'fill') {
      events.onSubmit = function () {
        showNotice(message('formSubmitted'));
        pollSession();
      };
    }
    configuration.events = events;

    const actions = {
      history: requestHistory,
      compare: function () { return openComparison('compare'); },
      snapshot: snapshot,
      rename: function () { return rename(); },
      publishPdf: async function () {
        const data = await request(urls.publishPdf, 'POST', context({ revision_id: options.revisionId }));
        await finishOperation('pdf', data);
      },
      fromTemplate: createFromTemplate,
      saveCopy: downloadCopy
    };
    if (root) root.querySelectorAll('[data-office-action]').forEach(function (button) {
      button.addEventListener('click', function () {
        const action = actions[button.dataset.officeAction];
        if (action) return run(action);
      });
    });

    function dispose() {
      state.disposed = true;
      global.clearTimeout(state.pollTimer);
      if (state.activeDialog) state.activeDialog.close();
      if (state.copyRequest) {
        global.clearTimeout(state.copyRequest.timer);
        state.copyRequest.reject(new Error(message('requestFailed')));
        state.copyRequest = null;
      }
    }

    global.addEventListener('pagehide', dispose, { once: true });
    doc.addEventListener('visibilitychange', function () { if (!doc.hidden) pollSession(); });
    try {
      if (!global.DocsAPI || !global.DocsAPI.DocEditor) throw new Error(message('editorUnavailable'));
      state.editor = new global.DocsAPI.DocEditor('dmsf-onlyoffice-editor', configuration);
      global.dmsfOnlyOfficeEditor = state.editor;
      pollSession();
      schedulePoll();
      try {
        const pending = JSON.parse(global.sessionStorage.getItem(storageKey) || 'null');
        if (pending && pending.operation_id &&
            ((pending.kind === 'pdf' && urls.publishPdf) || (pending.kind === 'template' && urls.createFromTemplate))) {
          run(function () { return finishOperation(pending.kind, { pending: true, operation_id: pending.operation_id }); });
        }
      } catch (_) { /* A malformed or inaccessible browser entry does not block editing. */ }
    } catch (error) {
      showError(error);
    }

    return { dispose: dispose, requestHistory: requestHistory, pollSession: pollSession };
  }

  global.DmsfOnlyoffice = { mount: mount };
})(window);
