const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_admin_reader_list_ui.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const selector = 'details[data-b270-active-readers-key], details[data-b270-admin-disclosure-key]';
const scriptureKey = '/reading/admin:session-1:scripture-frames';
const scriptureStorageKey = `b270-admin-disclosure:${scriptureKey}`;
const storageKey = (key = '/reading/admin:session-1') => `b270-active-readers:${key}`;

function harness({ storage = new Map(), blocked = false } = {}) {
  const nodes = [];
  const documentListeners = new Map();
  const windowListeners = new Map();
  const writes = [];
  const listen = (listeners, type, callback, capture = false) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push({ callback, capture });
  };
  const document = {
    querySelectorAll(query) {
      assert.equal(query, selector);
      return nodes.filter((node) => node.isConnected && node.matches(query));
    },
    addEventListener: (...args) => listen(documentListeners, ...args)
  };
  const context = vm.createContext({ document, addEventListener: (...args) => listen(windowListeners, ...args) });
  context.window = context;
  Object.defineProperty(context, 'sessionStorage', {
    get() {
      if (blocked === 'access') throw new Error('Storage blocked');
      return {
        getItem(key) {
          if (blocked === 'read') throw new Error('Storage read blocked');
          return storage.get(key) ?? null;
        },
        setItem(key, value) {
          if (blocked === 'write') throw new Error('Storage write blocked');
          writes.push([key, value]);
          storage.set(key, value);
        }
      };
    }
  });
  context.fetch = () => assert.fail('Disclosure preferences need no requests');
  const emit = (type, target = document, onWindow = false) => {
    for (const { callback } of (onWindow ? windowListeners : documentListeners).get(type) || []) callback({ target });
  };
  return {
    document, documentListeners, windowListeners, context, storage, writes, emit,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    details(key = '/reading/admin:session-1', open = true, generic = false) {
      const element = {
        open, isConnected: true, dataset: key == null ? {} : { [generic ? 'b270AdminDisclosureKey' : 'b270ActiveReadersKey']: key },
        matches: (query) => query === selector && key != null
      };
      nodes.push(element);
      return element;
    }
  };
}

for (const saved of [undefined, '', 'invalid', 'false']) {
  test(`missing or invalid stored preference (${saved}) retains the expanded default`, () => {
    const h = harness({ storage: new Map([[storageKey(), saved]]) });
    const list = h.details();
    h.evaluate();
    assert.equal(list.open, true);
    assert.deepEqual(h.writes, []);
  });
}

for (const state of ['open', 'closed']) {
  test(`restores a saved ${state} choice after a full reload`, () => {
    const storage = new Map([[storageKey(), state]]);
    for (let reload = 0; reload < 2; reload++) {
      const h = harness({ storage });
      const list = h.details();
      h.evaluate();
      assert.equal(list.open, state === 'open');
    }
  });
}

test('Scripture frames default open and remember their toggle independently of active readers', () => {
  const storage = new Map();
  const h = harness({ storage });
  const active = h.details();
  const scripture = h.details(scriptureKey, true, true);
  h.evaluate();
  assert.equal(scripture.open, true);
  scripture.open = false;
  h.emit('toggle', scripture);
  assert.equal(storage.get(scriptureStorageKey), 'closed');
  assert.equal(active.open, true);
  assert.equal(storage.has(storageKey()), false);

  scripture.isConnected = false;
  const replacement = h.details(scriptureKey, true, true);
  h.emit('turbo:load');
  assert.equal(replacement.open, false);
  replacement.open = true;
  h.emit('toggle', replacement);
  assert.equal(storage.get(scriptureStorageKey), 'open');

  storage.set(scriptureStorageKey, 'closed');
  const reload = harness({ storage });
  const restored = reload.details(scriptureKey, true, true);
  const readers = reload.details();
  const newSession = reload.details('/reading/admin:session-2:scripture-frames', true, true);
  reload.evaluate();
  assert.equal(restored.open, false);
  assert.equal(readers.open, true);
  assert.equal(newSession.open, true);
});

test('native toggles save both choices and use capture because toggle does not bubble', () => {
  const h = harness();
  const list = h.details();
  h.evaluate();
  assert.equal(h.documentListeners.get('toggle')[0].capture, true);
  for (const open of [false, true, false]) {
    list.open = open;
    h.emit('toggle', list);
    assert.equal(h.storage.get(storageKey()), open ? 'open' : 'closed');
  }
  assert.equal(h.writes.length, 3);
});

test('sorting and Turbo replacement restore the preference without changing alumni', () => {
  const h = harness();
  const original = h.details();
  const alumni = h.details(null, false);
  h.evaluate();
  original.open = false;
  h.emit('toggle', original);
  original.isConnected = false;
  const sorted = h.details();
  h.emit('turbo:load');
  assert.equal(sorted.open, false);
  assert.equal(alumni.open, false);
  alumni.open = true;
  h.emit('toggle', alumni);
  assert.equal(h.writes.length, 1);
});

test('new sign-in sessions and separate mounts use independent preferences', () => {
  const h = harness({ storage: new Map([[storageKey(), 'closed']]) });
  const original = h.details();
  const otherSession = h.details('/reading/admin:session-2');
  const otherMount = h.details('/another/admin:session-1');
  h.evaluate();
  assert.equal(original.open, false);
  assert.equal(otherSession.open, true);
  assert.equal(otherMount.open, true);
});

for (const blocked of ['access', 'read', 'write']) {
  test(`blocked storage ${blocked} keeps native toggling and in-page Turbo memory working`, () => {
    const h = harness({ blocked });
    const first = h.details();
    h.evaluate();
    assert.equal(first.open, true);
    first.open = false;
    h.emit('toggle', first);
    first.isConnected = false;
    const replacement = h.details();
    h.emit('turbo:load');
    assert.equal(replacement.open, false);
  });
}

for (const event of ['turbo:before-cache', 'pagehide']) {
  test(`${event} saves a pending native toggle before its event is delivered`, () => {
    const h = harness();
    const list = h.details();
    h.evaluate();
    list.open = false;
    h.emit(event, h.document, event === 'pagehide');
    assert.equal(h.storage.get(storageKey()), 'closed');
    list.open = true;
    h.emit('pageshow', h.document, true);
    assert.equal(list.open, false);
  });
}

test('repeat script execution installs one listener set without reverting a pending user toggle', () => {
  const h = harness({ storage: new Map([[storageKey(), 'closed']]) });
  const list = h.details();
  h.evaluate();
  list.open = true;
  h.evaluate();
  h.evaluate();
  assert.equal(list.open, true);
  for (const handlers of [...h.documentListeners.values(), ...h.windowListeners.values()]) assert.equal(handlers.length, 1);
  h.emit('toggle', list);
  assert.equal(h.storage.get(storageKey()), 'open');
});

test('detached disclosure events cannot overwrite the replacement state', () => {
  const h = harness();
  const old = h.details();
  h.evaluate();
  old.isConnected = false;
  old.open = false;
  h.details();
  h.emit('turbo:load');
  h.emit('toggle', old);
  assert.deepEqual(h.writes, []);
});

test('pages without a disclosure and unrelated toggle targets are harmless', () => {
  const h = harness();
  h.evaluate();
  h.emit('toggle', {});
  h.emit('toggle', h.details(''));
  h.emit('turbo:load');
  h.emit('pageshow', h.document, true);
  assert.deepEqual(h.writes, []);
});
