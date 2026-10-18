const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_comment_drafts.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const key = 'bible270:draft:reader:1:root';
const pendingKey = 'bible270:draft:pending';
const savedMessage = 'Draft saved in this browser.';
const warning = 'Draft couldn’t be saved. Keep this page open until posting.';
const formSelector = "form[data-b270-draft='true']";

function events() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(callback);
    },
    emit(type, properties = {}) {
      const event = { type, target: this, defaultPrevented: false,
        preventDefault() { this.defaultPrevented = true; }, ...properties };
      for (const callback of listeners.get(type) || []) callback(event);
      return event;
    }
  };
}

function memoryStorage() {
  return {
    data: new Map(), writes: 0, failWrites: false,
    getItem(key) { return this.data.get(key) ?? null; },
    setItem(key, value) {
      this.writes++;
      if (this.failWrites) throw new Error('QuotaExceededError');
      this.data.set(key, value);
    },
    removeItem(key) { this.data.delete(key); }
  };
}

function storedDraft(overrides = {}) {
  return { body: 'Restorable reflection', track: 'ot', bodyFormat: 'markdown',
    savedAt: Date.now(), revision: 'original', ...overrides };
}

function harness({ local = memoryStorage(), session = memoryStorage(), blocked = false, hash = '' } = {}) {
  const forms = [];
  const observers = [];
  const document = Object.assign(events(), { documentElement: {} });
  document.querySelectorAll = (selector) => {
    assert.equal(selector, formSelector);
    return forms;
  };
  const window = Object.assign(events(), { sessionStorage: session, location: { hash } });
  Object.defineProperty(window, 'localStorage', {
    get() { if (blocked) throw new Error('SecurityError'); return local; }
  });
  class MutationObserver {
    constructor(callback) { observers.push(callback); }
    observe() {}
  }
  const context = vm.createContext({ window, document, MutationObserver });
  return {
    local, session, window, document, observers,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    mutate: () => observers.forEach((callback) => callback()),
    form(dataset = {}) {
      const body = { value: '' };
      const track = { value: '', options: [{ value: '' }, { value: 'ot' }, { value: 'nt' }] };
      const format = { value: 'plain' };
      const announcements = [];
      let text = '';
      const status = {
        get textContent() { return text; },
        set textContent(value) { text = value; announcements.push(value); }
      };
      const nodes = new Map([
        ["textarea[name='comment[body]']", body], ["select[name='comment[track]']", track],
        ['[data-b270-body-format]', format], ['[data-b270-draft-status]', status]
      ]);
      const form = Object.assign(events(), {
        dataset: { b270DraftKey: key, ...dataset }, body, track, format, status, announcements,
        querySelector(selector) {
          assert.ok(nodes.has(selector), `Unexpected selector: ${selector}`);
          return nodes.get(selector);
        },
        matches(selector) { assert.equal(selector, formSelector); return true; }
      });
      forms.push(form);
      return form;
    },
    submitEnd(form, success) { document.emit('turbo:submit-end', { target: form, detail: { success } }); }
  };
}

test('successful saves persist body, track and format without repeated live-region writes', () => {
  const h = harness();
  const form = h.form();
  h.evaluate();
  form.body.value = 'First thought';
  form.track.value = 'ot';
  form.format.value = 'markdown';
  form.emit('input');
  const first = JSON.parse(h.local.getItem(key));
  assert.equal(first.body, form.body.value);
  assert.equal(first.track, 'ot');
  assert.equal(first.bodyFormat, 'markdown');
  assert.equal(typeof first.savedAt, 'number');
  assert.ok(first.revision);
  form.emit('change');
  assert.equal(h.local.writes, 1, 'unchanged drafts are not rewritten');
  form.body.value += ' and another';
  form.emit('input');
  h.window.emit('pagehide');
  assert.equal(JSON.parse(h.local.getItem(key)).body, form.body.value);
  assert.deepEqual(form.announcements, [savedMessage]);
  form.body.value = '  \n';
  form.emit('input');
  assert.equal(h.local.getItem(key), null);
  assert.deepEqual(form.announcements, [savedMessage, '']);
});

for (const failure of ['missing', 'blocked getter', 'quota', 'blocked methods']) {
  test(`${failure}: failed saves warn quietly and never prevent posting`, () => {
    const local = failure === 'missing' ? null : memoryStorage();
    if (failure === 'quota') local.failWrites = true;
    if (failure === 'blocked methods') {
      for (const method of ['getItem', 'setItem', 'removeItem']) {
        local[method] = () => { throw new Error('SecurityError'); };
      }
    }
    const h = harness({ local, blocked: failure === 'blocked getter' });
    const form = h.form();
    h.evaluate();
    form.body.value = 'Keep this reflection';
    form.emit('input');
    assert.equal(form.status.textContent, warning);
    form.body.value += ' while typing';
    form.emit('input');
    form.emit('change');
    h.window.emit('pagehide');
    assert.equal(form.emit('submit').defaultPrevented, false);
    h.submitEnd(form, false);
    assert.equal(form.body.value, 'Keep this reflection while typing');
    assert.equal(h.session.getItem(pendingKey), null);
    assert.deepEqual(form.announcements, [warning]);
    form.body.value = '';
    form.emit('input');
    assert.equal(form.status.textContent, '');
  });
}

test('quota failure preserves the last saved draft and announces recovery once', () => {
  const h = harness();
  const form = h.form();
  h.evaluate();
  form.body.value = 'Saved version';
  form.emit('input');
  h.local.failWrites = true;
  form.body.value = 'Unsaved version';
  form.emit('input');
  form.emit('change');
  assert.equal(JSON.parse(h.local.getItem(key)).body, 'Saved version');
  assert.equal(form.body.value, 'Unsaved version');
  assert.equal(form.status.textContent, warning);
  h.local.failWrites = false;
  form.emit('input');
  form.emit('change');
  assert.equal(JSON.parse(h.local.getItem(key)).body, 'Unsaved version');
  assert.deepEqual(form.announcements, [savedMessage, warning, savedMessage]);
});

test('restoration, validation errors, mutation scans and repeated initialization remain safe', () => {
  const h = harness();
  h.local.setItem(key, JSON.stringify(storedDraft()));
  const form = h.form();
  h.evaluate();
  assert.equal(form.body.value, 'Restorable reflection');
  assert.equal(form.track.value, 'ot');
  assert.equal(form.format.value, 'markdown');
  assert.deepEqual(form.announcements, ['Draft restored from this browser.']);
  form.body.value = 'Editing restored reflection';
  h.evaluate();
  h.mutate();
  h.window.emit('pageshow');
  assert.equal(form.body.value, 'Editing restored reflection');
  assert.equal(h.observers.length, 1);
  for (const type of ['input', 'change', 'submit']) assert.equal(form.listeners.get(type).length, 1);
  assert.equal(h.document.listeners.get('turbo:submit-end').length, 1);
  assert.equal(h.window.listeners.get('pagehide').length, 1);
  assert.equal(h.window.listeners.get('pageshow').length, 1);
  assert.equal(form.announcements.length, 1);
  const invalid = h.form({ b270DraftErrors: 'true' });
  invalid.body.value = 'Server validation value';
  h.mutate();
  assert.equal(invalid.body.value, 'Server validation value');
  assert.deepEqual(invalid.announcements, []);
  const inserted = h.form();
  h.mutate();
  assert.equal(inserted.body.value, 'Restorable reflection');
});

for (const success of [false, true]) {
  for (const newerRevision of [false, true]) {
    test(`Turbo submit success=${success}, newer revision=${newerRevision}: clearing stays revision-safe`, () => {
      const h = harness();
      const form = h.form();
      h.evaluate();
      form.body.value = 'Posting reflection';
      assert.equal(form.emit('submit').defaultPrevented, false);
      const submitted = JSON.parse(h.local.getItem(key));
      assert.deepEqual(JSON.parse(h.session.getItem(pendingKey)), { key, revision: submitted.revision });
      if (newerRevision) h.local.setItem(key, JSON.stringify(storedDraft({ revision: 'newer' })));
      h.submitEnd(form, success);
      assert.equal(h.session.getItem(pendingKey), null);
      assert.equal(h.local.getItem(key) === null, success && !newerRevision);
      if (newerRevision) assert.equal(JSON.parse(h.local.getItem(key)).revision, 'newer');
    });
  }
}

test('successful Turbo replacement settles pending before restoring the posted form', () => {
  const h = harness();
  const form = h.form();
  h.evaluate();
  form.body.value = 'Posting reflection';
  form.emit('submit');
  const replacement = h.form({ b270DraftPosted: 'true' });
  h.mutate();
  assert.equal(h.local.getItem(key), null);
  assert.equal(h.session.getItem(pendingKey), null);
  assert.equal(replacement.body.value, '');
  assert.deepEqual(replacement.announcements, []);
});

for (const hash of ['', '#comment-123']) {
  test(`full-page return with hash ${JSON.stringify(hash)} settles only confirmed posts`, () => {
    const h = harness({ hash });
    h.local.setItem(key, JSON.stringify(storedDraft()));
    h.session.setItem(pendingKey, JSON.stringify({ key, revision: 'original' }));
    const form = h.form();
    h.evaluate();
    assert.equal(h.session.getItem(pendingKey), null);
    assert.equal(h.local.getItem(key) === null, !!hash);
    assert.equal(form.body.value, hash ? '' : 'Restorable reflection');
  });
}

test('unavailable session storage does not block posting or claim that a local save failed', () => {
  const h = harness({ session: null });
  const form = h.form();
  h.evaluate();
  form.body.value = 'Reflection';
  assert.equal(form.emit('submit').defaultPrevented, false);
  h.submitEnd(form, true);
  assert.equal(JSON.parse(h.local.getItem(key)).body, 'Reflection');
  assert.deepEqual(form.announcements, [savedMessage]);
});
