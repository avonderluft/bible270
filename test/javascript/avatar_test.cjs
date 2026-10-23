const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_avatar_ui.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const selector = 'img[data-b270-avatar]';
const failedAttribute = 'data-b270-avatar-failed';
const origin = 'https://bible270.test';
const epoch = 1700000000000;

class Image {
  constructor({ src = '/avatars/reader.png', uploaded, marked = true,
    complete = true, naturalWidth = 0, failed = false } = {}) {
    this.dataset = {};
    if (marked) this.dataset.b270Avatar = '';
    if (uploaded !== undefined) this.dataset.b270AvatarUploaded = uploaded;
    this.attributes = {};
    if (src !== null) this.attributes.src = src;
    if (failed) this.attributes[failedAttribute] = '';
    this.complete = complete;
    this.naturalWidth = naturalWidth;
    this.isConnected = true;
    this.sourceWrites = [];
  }
  matches(value) {
    assert.equal(value, selector);
    return Object.hasOwn(this.dataset, 'b270Avatar');
  }
  querySelectorAll(value) {
    assert.equal(value, selector);
    return [];
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  removeAttribute(name) { delete this.attributes[name]; }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === 'src') {
      this.sourceWrites.push(String(value));
      // Requests stay pending until the test supplies a cached result or event.
      this.complete = false;
      this.naturalWidth = 0;
    }
  }
}

function harness(images = []) {
  const listeners = new Map();
  const windowListeners = new Map();
  const observers = [];
  const timers = new Map();
  const scheduled = [];
  let now = epoch;
  let nextTimer = 1;
  const addListener = (registry, type, callback, capture = false) => {
    if (!registry.has(type)) registry.set(type, []);
    registry.get(type).push({ callback, capture });
  };
  const document = {
    baseURI: `${origin}/read/today`,
    documentElement: {},
    querySelectorAll(value) {
      assert.equal(value, selector);
      return images.filter((image) => image.isConnected && image.matches(value));
    },
    addEventListener(type, callback, capture) {
      addListener(listeners, type, callback, capture);
    }
  };
  const window = {
    location: { origin },
    addEventListener(type, callback, capture) {
      addListener(windowListeners, type, callback, capture);
    }
  };
  class MutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.observations = [];
      observers.push(this);
    }
    observe(target, options) { this.observations.push({ target, options }); }
  }
  const context = vm.createContext({
    document, window, MutationObserver, URL,
    Date: class extends Date { static now() { return now; } },
    setTimeout(callback, delay) {
      const id = nextTimer++;
      const timer = { id, callback, delay, due: now + delay };
      timers.set(id, timer);
      scheduled.push(timer);
      return id;
    },
    clearTimeout(id) { timers.delete(id); }
  });
  const dispatch = (registry, type, target, captureOnly = false) => {
    for (const listener of registry.get(type) || []) {
      if (!captureOnly || listener.capture === true) {
        listener.callback({ type, target, bubbles: false });
      }
    }
  };
  return {
    document, window, images, listeners, windowListeners, observers, timers, scheduled,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit: (type, target = document) => dispatch(listeners, type, target),
    pageshow: () => dispatch(windowListeners, 'pageshow', window),
    imageEvent(type, image) {
      assert.ok(type === 'load' || type === 'error');
      image.complete = true;
      image.naturalWidth = type === 'load' ? 64 : 0;
      // Image load/error events reach document only through capture, not bubbling.
      dispatch(listeners, type, image, true);
    },
    added(...nodes) {
      for (const observer of observers) observer.callback([{ addedNodes: nodes }]);
    },
    advance(milliseconds) {
      const end = now + milliseconds;
      let executions = 0;
      while (true) {
        const timer = [...timers.values()].filter((entry) => entry.due <= end)
          .sort((a, b) => a.due - b.due || a.id - b.id)[0];
        if (!timer) break;
        assert.ok(++executions < 100, 'timer callbacks must not loop indefinitely');
        now = timer.due;
        timers.delete(timer.id);
        timer.callback();
      }
      now = end;
    }
  };
}

function assertFailed(image) {
  assert.equal(image.getAttribute(failedAttribute), '');
}

function assertHealthy(image) {
  assert.equal(image.getAttribute(failedAttribute), null);
}

function repeatInitialization(h) {
  h.window.Bible270AvatarUI.initialize();
  h.emit('turbo:load');
  h.emit('turbo:render');
  h.pageshow();
  h.evaluate();
}

test('initial scan marks cached failures but clears successful cached images and ignores pending/unmarked images', () => {
  const broken = new Image();
  const cached = new Image({ naturalWidth: 64, failed: true });
  const pending = new Image({ complete: false });
  const unmarked = new Image({ marked: false });
  const h = harness([broken, cached, pending, unmarked]);
  h.evaluate();

  assertFailed(broken);
  for (const image of [cached, pending, unmarked]) assertHealthy(image);
  assert.deepEqual(h.scheduled.map((timer) => timer.delay), [500]);
  h.advance(500);
  assert.equal(broken.sourceWrites.length, 1);
  for (const image of [cached, pending, unmarked]) assert.deepEqual(image.sourceWrites, []);
});

for (const src of [null, '']) {
  test(`cached failure with ${src === null ? 'missing' : 'empty'} src is marked without scheduling retries`, () => {
    const image = new Image({ src });
    const h = harness([image]);
    h.evaluate();
    repeatInitialization(h);
    assertFailed(image);
    assert.equal(h.scheduled.length, 0);
    assert.deepEqual(image.sourceWrites, []);
  });
}

test('captured non-bubbling error/load events handle dynamic avatars without a scan', () => {
  const h = harness();
  h.evaluate();
  const image = new Image({ complete: false });
  h.images.push(image);
  for (const type of ['load', 'error']) {
    assert.equal(h.listeners.get(type).length, 1);
    assert.equal(h.listeners.get(type)[0].capture, true);
  }

  h.imageEvent('error', image);
  assertFailed(image);
  assert.equal(h.timers.size, 1);
  h.imageEvent('load', image);
  assertHealthy(image);
  assert.equal(h.timers.size, 0);
  h.advance(5000);
  assert.deepEqual(image.sourceWrites, []);
});

test('captured events ignore unmarked images and non-element targets', () => {
  const h = harness();
  h.evaluate();
  const image = new Image({ marked: false, failed: true });
  h.imageEvent('error', image);
  h.imageEvent('load', image);
  h.emit('error', {});
  h.emit('load', h.document);
  assertFailed(image);
  assert.equal(h.scheduled.length, 0);
});

for (const uploaded of [undefined, 'true']) {
  test(`retries ${uploaded ? 'uploaded' : 'provider'} avatars at 500/1500ms, deduplicates events/initialization, and caps at two`, () => {
    const image = new Image({ uploaded });
    const h = harness([image]);
    h.evaluate();
    const firstTimer = [...h.timers.keys()][0];
    h.advance(250);
    h.imageEvent('error', image);
    h.imageEvent('error', image);
    repeatInitialization(h);
    assert.deepEqual([...h.timers.keys()], [firstTimer]);
    assert.equal(h.scheduled.length, 1);
    h.advance(249);
    assert.equal(image.sourceWrites.length, 0);
    h.advance(1);
    assert.equal(image.sourceWrites.length, 1);
    assert.equal(h.timers.size, 0);

    h.imageEvent('error', image);
    const secondTimer = [...h.timers.keys()][0];
    h.advance(750);
    h.imageEvent('error', image);
    repeatInitialization(h);
    assert.deepEqual([...h.timers.keys()], [secondTimer]);
    assert.deepEqual(h.scheduled.map((timer) => timer.delay), [500, 1500]);
    h.advance(749);
    assert.equal(image.sourceWrites.length, 1);
    h.advance(1);
    assert.equal(image.sourceWrites.length, 2);

    h.imageEvent('error', image);
    h.imageEvent('error', image);
    repeatInitialization(h);
    h.advance(10000);
    assertFailed(image);
    assert.equal(h.timers.size, 0);
    assert.equal(h.scheduled.length, 2);
    assert.equal(image.sourceWrites.length, 2);
  });
}

for (const { name, src, uploaded } of [
  { name: 'signed external provider', src: 'https://provider.test/avatar?token=a%2Fb%2Bc&size=64&signature=X+Y%3D#photo' },
  { name: 'external upload', src: 'https://storage.test/avatar?X-Amz-Signature=a%2Fb&X-Amz-Credential=x+y', uploaded: 'true' },
  { name: 'protocol-relative external upload', src: '//storage.test/avatar?signature=a%2Bb&size=64', uploaded: 'true' },
  { name: 'same-origin provider', src: '/provider/avatar?signature=a%2Fb+z&size=64' },
  { name: 'non-upload marker', src: '/avatars/reader.png?size=64', uploaded: 'false' },
  { name: 'different-port upload', src: 'https://bible270.test:444/avatar?signature=a%2Fb', uploaded: 'true' },
  { name: 'different-scheme upload', src: 'http://bible270.test/avatar?signature=a%2Fb', uploaded: 'true' }
]) {
  test(`${name} URL is preserved byte-for-byte on both retries`, () => {
    const image = new Image({ src, uploaded });
    const h = harness([image]);
    h.evaluate();
    h.advance(500);
    h.imageEvent('error', image);
    h.advance(1500);
    assert.deepEqual(image.sourceWrites, [src, src]);
  });
}

for (const src of [
  '/rails/active_storage/blobs/redirect/signed/avatar.png?size=64&tag=one&tag=two&token=a%2Bb#photo',
  `${origin}/uploads/avatar.png?size=64&_b270_avatar_retry=old&tag=one&tag=two#photo`,
  '../uploads/avatar.png?size=64&tag=one&tag=two#photo'
]) {
  test(`same-origin uploaded URL is cache-busted without losing existing params: ${src}`, () => {
    const image = new Image({ src, uploaded: 'true' });
    const h = harness([image]);
    const original = new URL(src, h.document.baseURI);
    const originalParams = [...original.searchParams].filter(([key]) => key !== '_b270_avatar_retry');
    h.evaluate();
    for (const [index, delay] of [500, 1500].entries()) {
      h.advance(delay);
      const retried = new URL(image.getAttribute('src'));
      assert.equal(retried.origin, original.origin);
      assert.equal(retried.pathname, original.pathname);
      assert.equal(retried.hash, original.hash);
      assert.deepEqual([...retried.searchParams].filter(([key]) => key !== '_b270_avatar_retry'), originalParams);
      assert.deepEqual(retried.searchParams.getAll('_b270_avatar_retry'), [
        `${epoch + (index === 0 ? 500 : 2000)}-${index + 1}`
      ]);
      h.imageEvent('error', image);
    }
    assert.equal(h.timers.size, 0);
    assert.equal(image.sourceWrites.length, 2);
  });
}

for (const completion of ['load event', 'cached scan', 'retry callback']) {
  test(`${completion} clears failure and prevents a pending second retry after success`, () => {
    const image = new Image({ uploaded: 'true' });
    const h = harness([image]);
    h.evaluate();
    h.advance(500);
    h.imageEvent('error', image);
    assertFailed(image);
    assert.equal(h.timers.size, 1);

    image.complete = true;
    image.naturalWidth = 64;
    if (completion === 'load event') h.imageEvent('load', image);
    else if (completion === 'cached scan') h.window.Bible270AvatarUI.initialize();
    else h.advance(1500);
    assertHealthy(image);
    assert.equal(h.timers.size, 0);
    h.advance(10000);
    assert.equal(image.sourceWrites.length, 1);
  });
}

test('disconnecting an image before its retry prevents src writes', () => {
  const image = new Image({ uploaded: 'true' });
  const h = harness([image]);
  h.evaluate();
  image.isConnected = false;
  h.advance(500);
  repeatInitialization(h);
  h.advance(5000);
  assert.equal(h.timers.size, 0);
  assert.equal(h.scheduled.length, 1);
  assert.deepEqual(image.sourceWrites, []);
});

test('source replacement before a retry is not overwritten by the stale callback', () => {
  const image = new Image({ uploaded: 'true' });
  const h = harness([image]);
  h.evaluate();
  const replacement = '/uploads/new.png?size=96';
  image.setAttribute('src', replacement);
  h.advance(500);
  assert.deepEqual(image.sourceWrites, [replacement]);
  assert.equal(h.timers.size, 0);

  h.imageEvent('error', image);
  assert.deepEqual(h.scheduled.map((timer) => timer.delay), [500, 500]);
  h.advance(500);
  const retried = new URL(image.getAttribute('src'));
  assert.equal(retried.pathname, '/uploads/new.png');
  assert.equal(retried.searchParams.get('size'), '96');
  assert.equal(retried.searchParams.get('_b270_avatar_retry'), `${epoch + 1000}-1`);
});

test('an error for a replacement source cancels the old timer and resets its retry budget', () => {
  const image = new Image({ uploaded: 'true' });
  const h = harness([image]);
  h.evaluate();
  h.advance(500);
  h.imageEvent('error', image);
  const staleTimer = [...h.timers.keys()][0];
  h.advance(100);
  image.setAttribute('src', '/uploads/replacement.png');
  h.imageEvent('error', image);
  assert.equal(h.timers.has(staleTimer), false);
  assert.equal(h.timers.size, 1);
  assert.deepEqual(h.scheduled.map((timer) => timer.delay), [500, 1500, 500]);
  h.advance(500);
  assert.match(image.getAttribute('src'), /replacement\.png\?_b270_avatar_retry=1700000001100-1$/);
  h.imageEvent('error', image);
  h.advance(1500);
  assert.match(image.getAttribute('src'), /replacement\.png\?_b270_avatar_retry=1700000002600-2$/);
  h.imageEvent('error', image);
  assert.equal(h.timers.size, 0);
  assert.equal(image.sourceWrites.length, 4);
});

for (const event of ['turbo:load', 'turbo:render', 'pageshow']) {
  test(`${event} scans new cached results and does not duplicate their retry timers`, () => {
    const h = harness();
    h.evaluate();
    const broken = new Image();
    const cached = new Image({ naturalWidth: 64, failed: true });
    h.images.push(broken, cached);
    const initialize = () => event === 'pageshow' ? h.pageshow() : h.emit(event);
    initialize();
    initialize();
    assertFailed(broken);
    assertHealthy(cached);
    assert.equal(h.timers.size, 1);
    assert.equal(h.scheduled.length, 1);
    h.advance(500);
    assert.equal(broken.sourceWrites.length, 1);
    assert.deepEqual(cached.sourceWrites, []);
  });
}

test('repeated script execution preserves the singleton, listeners, observer, and retry state while scanning new images', () => {
  const image = new Image();
  const h = harness([image]);
  h.evaluate();
  const singleton = h.window.Bible270AvatarUI;
  const firstTimer = [...h.timers.keys()][0];
  const newImage = new Image();
  h.images.push(newImage);
  h.evaluate();
  h.evaluate();
  assert.equal(h.window.Bible270AvatarUI, singleton);
  assertFailed(newImage);
  assert.equal(h.timers.has(firstTimer), true);
  assert.equal(h.timers.size, 2);
  assert.equal(h.scheduled.length, 2);
  assert.deepEqual([...h.listeners.keys()].sort(), ['error', 'load', 'turbo:load', 'turbo:render']);
  for (const callbacks of h.listeners.values()) assert.equal(callbacks.length, 1);
  assert.deepEqual([...h.windowListeners.keys()], ['pageshow']);
  assert.equal(h.windowListeners.get('pageshow').length, 1);
  assert.equal(h.observers.length, 1);
  assert.equal(h.observers[0].observations.length, 1);
  assert.equal(h.observers[0].observations[0].target, h.document.documentElement);
  // Normalize VM objects before comparing across realms.
  assert.deepEqual(JSON.parse(JSON.stringify(h.observers[0].observations[0].options)), {
    childList: true, subtree: true
  });
});

test('MutationObserver inspects added cached-failed images and nested avatars, ignoring text nodes and pending images', () => {
  const h = harness();
  h.evaluate();
  const direct = new Image();
  const nested = new Image();
  const cached = new Image({ naturalWidth: 64, failed: true });
  const pending = new Image({ complete: false });
  const unmarked = new Image({ marked: false });
  const container = {
    matches(value) { assert.equal(value, selector); return false; },
    querySelectorAll(value) {
      assert.equal(value, selector);
      return [nested, cached, pending];
    }
  };
  h.added(direct, container, unmarked, { nodeType: 3 });
  h.added(direct, container);
  assertFailed(direct);
  assertFailed(nested);
  for (const image of [cached, pending, unmarked]) assertHealthy(image);
  assert.equal(h.timers.size, 2);
  assert.equal(h.scheduled.length, 2);
  h.advance(500);
  assert.equal(direct.sourceWrites.length, 1);
  assert.equal(nested.sourceWrites.length, 1);
  for (const image of [cached, pending, unmarked]) assert.deepEqual(image.sourceWrites, []);
});
