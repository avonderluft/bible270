const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_avatar_preview_ui.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const selector = 'img[data-b270-avatar-preview-src]';
const original = '/rails/active_storage/blobs/redirect/signed/original.jpg?signature=a%2Bb';

class Element {
  constructor(tag) {
    this.tag = tag;
    this.attributes = new Map();
    this.children = [];
    this.parent = null;
    this.style = {};
    this.className = '';
    this.classList = {
      add: (name) => { this.className = [...new Set([...this.className.split(' ').filter(Boolean), name])].join(' '); },
      remove: (name) => { this.className = this.className.split(' ').filter((value) => value !== name).join(' '); },
      contains: (name) => this.className.split(' ').includes(name)
    };
    this.complete = false;
    this.naturalWidth = 0;
    this.naturalHeight = 0;
    this.rect = { left: 100, right: 140, top: 80, bottom: 120, width: 40, height: 40 };
  }

  get isConnected() { return this.tag === 'document' || !!this.parent?.isConnected; }
  matches(value) {
    assert.equal(value, selector);
    return this.tag === 'img' && this.attributes.has('data-b270-avatar-preview-src');
  }
  setAttribute(name, value) { this.attributes.set(name, value); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  append(child) { child.parent = this; this.children.push(child); return child; }
  remove() {
    if (!this.parent) return;
    this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
  getBoundingClientRect() { return this.rect; }
}

function harness({ fine = true, width = 1000, height = 800, popupWidth = 302, popupHeight = 202 } = {}) {
  const document = new Element('document');
  document.body = document.append(new Element('body'));
  const documentListeners = new Map();
  const windowListeners = new Map();
  const timers = new Map();
  const requests = [];
  const created = [];
  const cached = new Map();
  const media = { matches: fine };
  let now = 0;
  let nextTimer = 0;
  const listen = (listeners, type, callback, capture = false) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push({ callback, capture });
  };
  document.addEventListener = (...args) => listen(documentListeners, ...args);
  document.createElement = (tag) => {
    const element = new Element(tag);
    created.push(element);
    if (tag === 'img') {
      Object.defineProperty(element, 'src', {
        get() { return this.getAttribute('src'); },
        set(value) {
          this.setAttribute('src', value);
          requests.push(value);
          const result = cached.get(value);
          this.complete = !!result;
          this.naturalWidth = result?.width || 0;
          this.naturalHeight = result?.height || 0;
          if (result?.synchronous) this[result.width ? 'onload' : 'onerror']?.();
        }
      });
    } else {
      element.getBoundingClientRect = () => {
        assert.equal(element.children[0].complete, true, 'measure only after load');
        assert.ok(element.children[0].naturalWidth > 0, 'never measure failed images');
        // Model the parent CSS's viewport-constrained dimensions including borders.
        return { width: Math.min(popupWidth, context.innerWidth - 32),
          height: Math.min(popupHeight, context.innerHeight - 32) };
      };
    }
    return element;
  };
  const context = vm.createContext({
    document, innerWidth: width, innerHeight: height,
    matchMedia(query) {
      assert.equal(query, '(hover: hover) and (pointer: fine)');
      return media;
    },
    addEventListener: (...args) => listen(windowListeners, ...args),
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { id, callback, due: now + delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id)
  });
  context.window = context;
  const emit = (type, target = document, extra = {}, onWindow = false) => {
    const event = { type, target, defaultPrevented: false, propagationStopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.propagationStopped = true; }, ...extra };
    const listeners = (onWindow ? windowListeners : documentListeners).get(type) || [];
    for (const { callback, capture } of listeners) {
      if (!['load', 'error'].includes(type) || capture) callback(event);
    }
    target[`on${type}`]?.(event);
    return event;
  };
  return {
    context, document, documentListeners, windowListeners, timers, requests, created, cached, media,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit,
    over: (target, pointerType = 'mouse') => emit('pointerover', target, { pointerType }),
    out: (target, relatedTarget = null) => emit('pointerout', target, { pointerType: 'mouse', relatedTarget }),
    avatar(url = original, rect = {}) {
      const avatar = new Element('img');
      avatar.setAttribute('data-b270-avatar', '');
      avatar.setAttribute('data-b270-avatar-preview-src', url);
      avatar.setAttribute('src', '/cropped-thumbnail.jpg');
      Object.assign(avatar.rect, rect);
      document.body.append(avatar);
      return avatar;
    },
    popups: () => document.body.children.filter((child) => child.classList.contains('b270-avatar-preview')),
    imageEvent(image, type, naturalWidth = 1200, naturalHeight = 800) {
      image.complete = true;
      image.naturalWidth = type === 'error' ? 0 : naturalWidth;
      image.naturalHeight = type === 'error' ? 0 : naturalHeight;
      return emit(type, image);
    },
    advance(milliseconds) {
      const end = now + milliseconds;
      let executions = 0;
      while (true) {
        const timer = [...timers.values()].filter((value) => value.due <= end)
          .sort((a, b) => a.due - b.due || a.id - b.id)[0];
        if (!timer) break;
        assert.ok(++executions < 100, 'timer loop terminates');
        now = timer.due;
        timers.delete(timer.id);
        timer.callback();
      }
      now = end;
    }
  };
}

function pendingPreview(h, avatar = h.avatar()) {
  h.over(avatar);
  h.advance(3000);
  const [popup] = h.popups();
  assert.ok(popup);
  assert.equal(popup.classList.contains('is-visible'), false);
  return { avatar, popup, image: popup.children[0] };
}

function visiblePreview(h, avatar) {
  const preview = pendingPreview(h, avatar);
  h.imageEvent(preview.image, 'load');
  assert.equal(preview.popup.classList.contains('is-visible'), true);
  return preview;
}

test('delegated hover waits a full 3000ms before requesting the unchanged original, then waits for load', () => {
  const h = harness();
  h.evaluate();
  const avatar = h.avatar(); // Also exercises dynamically inserted avatars.
  assert.deepEqual(h.created, []);
  h.over(avatar);
  h.advance(2999);
  assert.deepEqual(h.requests, []);
  assert.deepEqual(h.popups(), []);
  h.over(avatar); // Duplicate pointerover must not restart the delay.
  h.advance(1);
  const [popup] = h.popups();
  const image = popup.children[0];
  assert.deepEqual(h.requests, [original]);
  assert.equal(avatar.getAttribute('src'), '/cropped-thumbnail.jpg');
  assert.equal(popup.parent, h.document.body);
  assert.equal(popup.style.position, 'fixed');
  assert.equal(popup.getAttribute('aria-hidden'), 'true');
  assert.equal(image.alt, '');
  assert.equal(popup.classList.contains('is-visible'), false);
  h.advance(10000);
  assert.equal(popup.classList.contains('is-visible'), false);
  h.imageEvent(image, 'load');
  assert.equal(popup.classList.contains('is-visible'), true);
  assert.equal(popup.style.left, '152px');
  assert.equal(popup.style.top, '80px');
});

for (const url of [original, 'https://provider.example/avatar?s=40&crop=square&signature=a%2Bb#original']) {
  test(`original source is lazy and used verbatim: ${url}`, () => {
    const h = harness();
    const avatar = h.avatar(url);
    h.evaluate();
    h.over(avatar);
    h.advance(1000);
    h.out(avatar);
    h.advance(10000);
    assert.deepEqual(h.requests, []);
    assert.equal(h.timers.size, 0);
    visiblePreview(h, avatar);
    assert.deepEqual(h.requests, [url]);
  });
}

test('leave immediately hides the popup and removes it after the 200ms fade', () => {
  const h = harness();
  h.evaluate();
  const { avatar, popup, image } = visiblePreview(h);
  h.out(avatar);
  assert.equal(popup.classList.contains('is-visible'), false);
  assert.equal(image.onload, null);
  assert.equal(image.onerror, null);
  h.advance(199);
  assert.deepEqual(h.popups(), [popup]);
  h.advance(1);
  assert.deepEqual(h.popups(), []);
  assert.equal(h.timers.size, 0);
});

test('direct avatar changes cancel stale timers and always start a fresh 3-second delay', () => {
  const h = harness();
  const first = h.avatar();
  const second = h.avatar('https://provider.example/second');
  h.evaluate();
  h.over(first);
  const staleTimer = [...h.timers.values()][0].callback;
  h.advance(2999);
  h.out(first, second);
  h.over(second);
  staleTimer(); // Even a queued, previously cancelled callback must be harmless.
  h.out(first, second);
  h.advance(2999);
  assert.deepEqual(h.requests, []);
  h.advance(1);
  assert.deepEqual(h.requests, ['https://provider.example/second']);
});

test('late load/error from a departed avatar cannot show or cancel a new preview', () => {
  const h = harness();
  h.evaluate();
  const old = pendingPreview(h);
  const staleLoad = old.image.onload;
  const staleError = old.image.onerror;
  const second = h.avatar('https://provider.example/new');
  h.out(old.avatar, second);
  h.over(second);
  old.image.complete = true;
  old.image.naturalWidth = 500;
  staleLoad();
  staleError();
  assert.equal(old.popup.isConnected, true, 'a new hover does not interrupt the old fade');
  assert.equal(old.popup.classList.contains('is-visible'), false);
  h.advance(2999);
  assert.equal(h.requests.length, 1);
  h.advance(1);
  const [popup] = h.popups();
  h.imageEvent(popup.children[0], 'load');
  staleError();
  assert.equal(popup.classList.contains('is-visible'), true);
});

for (const synchronous of [false, true]) {
  test(`cached successful original shows without waiting for another load event (synchronous=${synchronous})`, () => {
    const h = harness();
    h.cached.set(original, { width: 1600, height: 900, synchronous });
    h.evaluate();
    h.over(h.avatar());
    h.advance(3000);
    assert.equal(h.popups()[0].classList.contains('is-visible'), true);
    assert.deepEqual(h.requests, [original]);
  });
}

for (const failure of ['error', 'cached', 'synchronous']) {
  test(`broken original stays hidden and cleans up: ${failure}`, () => {
    const h = harness();
    if (failure !== 'error') h.cached.set(original, { width: 0, synchronous: failure === 'synchronous' });
    h.evaluate();
    const { popup, image } = pendingPreview(h);
    const staleLoad = image.onload;
    if (failure === 'error') h.imageEvent(image, 'error');
    image.naturalWidth = 200;
    staleLoad?.();
    assert.equal(popup.classList.contains('is-visible'), false);
    h.advance(200);
    assert.deepEqual(h.popups(), []);
    assert.equal(h.timers.size, 0);
  });
}

test('an avatar error during the delay cancels the original request without changing the thumbnail', () => {
  const h = harness();
  h.evaluate();
  const avatar = h.avatar();
  h.over(avatar);
  h.advance(1000);
  h.imageEvent(avatar, 'error');
  assert.equal(h.timers.size, 0);
  h.advance(5000);
  assert.deepEqual(h.requests, []);
  assert.equal(avatar.getAttribute('src'), '/cropped-thumbnail.jpg');
});

for (const phase of ['delay', 'loading']) {
  test(`disconnecting the hovered avatar prevents display during ${phase}`, () => {
    const h = harness();
    h.evaluate();
    const avatar = h.avatar();
    h.over(avatar);
    if (phase === 'loading') h.advance(3000);
    const image = h.popups()[0]?.children[0];
    avatar.remove();
    if (image) h.imageEvent(image, 'load');
    else h.advance(3000);
    assert.deepEqual(h.popups(), []);
    assert.equal(h.timers.size, 0);
    assert.equal(h.requests.length, phase === 'loading' ? 1 : 0);
  });
}

for (const { name, options, rect, left, top } of [
  { name: 'right side', options: {}, rect: {}, left: 152, top: 80 },
  { name: 'right edge uses left side', options: {}, rect: { left: 930, right: 970 }, left: 616, top: 80 },
  { name: 'bottom edge', options: {}, rect: { top: 760 }, left: 152, top: 582 },
  { name: 'negative top and left', options: {}, rect: { left: -80, right: -40, top: -30 }, left: 16, top: 16 },
  { name: 'neither side fits', options: { width: 400 }, rect: { left: 180, right: 220 }, left: 16, top: 80 },
  { name: 'oversized original constrained by parent CSS', options: { width: 400, height: 300, popupWidth: 3000, popupHeight: 2000 }, rect: {}, left: 16, top: 16 },
  { name: 'offscreen right and bottom', options: {}, rect: { left: 1200, right: 1240, top: 950 }, left: 682, top: 582 }
]) {
  test(`loaded popup positioning respects border-inclusive dimensions and viewport margins: ${name}`, () => {
    const h = harness(options);
    h.evaluate();
    const { popup } = visiblePreview(h, h.avatar(original, rect));
    assert.equal(popup.style.left, `${left}px`);
    assert.equal(popup.style.top, `${top}px`);
  });
}

for (const { pointerType, fine, allowed } of [
  { pointerType: 'mouse', fine: true, allowed: true },
  { pointerType: 'pen', fine: true, allowed: true },
  { pointerType: 'touch', fine: true, allowed: false },
  { pointerType: '', fine: true, allowed: false },
  { pointerType: 'mouse', fine: false, allowed: false },
  { pointerType: 'pen', fine: false, allowed: false },
  { pointerType: 'touch', fine: false, allowed: false }
]) {
  test(`pointer eligibility: ${pointerType || 'unspecified'}, fine=${fine}`, () => {
    const h = harness({ fine });
    h.evaluate();
    const event = h.over(h.avatar(), pointerType);
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.propagationStopped, false);
    h.advance(3000);
    assert.equal(h.requests.length, allowed ? 1 : 0);
    assert.equal(h.popups().length, allowed ? 1 : 0);
  });
}

test('missing matchMedia and a capability change during the delay safely skip loading', () => {
  const h = harness();
  h.evaluate();
  h.over(h.avatar());
  h.media.matches = false;
  h.advance(3000);
  assert.deepEqual(h.requests, []);
  const missing = harness();
  delete missing.context.matchMedia;
  missing.evaluate();
  missing.over(missing.avatar());
  missing.advance(3000);
  assert.deepEqual(missing.requests, []);
});

const cleanups = [
  ['Escape', (h) => h.emit('keydown', h.document, { key: 'Escape' }), false],
  ['nested scroll', (h) => h.emit('scroll', new Element('section')), false],
  ['resize', (h) => h.emit('resize', h.context, {}, true), false],
  ['pagehide', (h) => h.emit('pagehide', h.context, {}, true), true],
  ['Turbo before-cache', (h) => h.emit('turbo:before-cache'), true],
  ['Turbo before-render', (h) => h.emit('turbo:before-render'), true],
  ['public reset', (h) => h.context.Bible270AvatarPreview.reset(), true],
  ['script re-evaluation', (h) => h.evaluate(), true]
];
for (const [name, cleanup, immediate] of cleanups) {
  for (const phase of ['delay', 'loading', 'visible', 'fading']) {
    test(`${name} cancels ${phase} work${immediate ? ' with immediate removal' : ''}`, () => {
      const h = harness();
      h.evaluate();
      const avatar = h.avatar();
      h.over(avatar);
      if (phase !== 'delay') h.advance(3000);
      const popup = h.popups()[0];
      const image = popup?.children[0];
      const staleLoad = image?.onload;
      const staleError = image?.onerror;
      if (phase === 'visible' || phase === 'fading') h.imageEvent(image, 'load');
      if (phase === 'fading') h.out(avatar);
      cleanup(h);
      if (image) { image.complete = true; image.naturalWidth = 900; }
      staleLoad?.();
      staleError?.();
      assert.equal(popup?.classList.contains('is-visible') || false, false);
      if (immediate) assert.deepEqual(h.popups(), []);
      h.advance(10000);
      assert.deepEqual(h.popups(), []);
      assert.equal(h.timers.size, 0);
      assert.equal(h.requests.length, phase === 'delay' ? 0 : 1);
      visiblePreview(h, avatar); // Cleanup does not disable future delegated hovers.
    });
  }
}

test('re-evaluation preserves the singleton and installs each delegated listener only once', () => {
  const h = harness();
  h.evaluate();
  const singleton = h.context.Bible270AvatarPreview;
  visiblePreview(h);
  h.evaluate();
  h.evaluate();
  assert.equal(h.context.Bible270AvatarPreview, singleton);
  for (const listeners of [h.documentListeners, h.windowListeners]) {
    for (const [type, callbacks] of listeners) assert.equal(callbacks.length, 1, type);
  }
  assert.equal(h.documentListeners.get('scroll')[0].capture, true);
  assert.deepEqual(h.popups(), []);
  assert.equal(h.timers.size, 0);
});

test('unmarked, empty-source, and non-element targets do not load originals', () => {
  const h = harness();
  h.evaluate();
  h.over(new Element('img'));
  h.over({});
  h.over(h.avatar(''));
  h.advance(3000);
  assert.deepEqual(h.requests, []);
  assert.deepEqual(h.popups(), []);
  assert.equal(h.timers.size, 0);
});

test('avatar links retain click and keyboard behavior, without touch or click interception', () => {
  const h = harness();
  const link = h.document.body.append(new Element('a'));
  link.setAttribute('href', '/profile/123');
  const avatar = h.avatar();
  avatar.remove();
  link.append(avatar);
  h.evaluate();
  for (const type of ['click', 'pointerdown', 'pointerup', 'touchstart']) {
    const event = h.emit(type, avatar, { pointerType: 'touch' });
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.propagationStopped, false);
    assert.equal(h.documentListeners.has(type), false);
  }
  h.over(avatar, 'touch');
  h.advance(3000);
  assert.deepEqual(h.requests, []);
  visiblePreview(h, avatar);
  for (const key of ['Enter', ' ', 'Escape']) {
    const event = h.emit('keydown', link, { key });
    assert.equal(event.defaultPrevented, false);
    assert.equal(event.propagationStopped, false);
    if (key !== 'Escape') assert.equal(h.popups()[0].classList.contains('is-visible'), true);
  }
  assert.equal(link.getAttribute('href'), '/profile/123');
});
