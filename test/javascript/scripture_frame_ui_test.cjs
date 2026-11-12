const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_scripture_frame_ui.html.erb');
const markup = readFileSync(filename, 'utf8');
const source = markup.replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const frame = { id: 17, reference: 'Psalm 23:1', text: 'The LORD is my shepherd,\nI shall not want.', translation: 'NASB95', attribution: '' };

class Element {
  constructor(tag) {
    this.tag = tag;
    this.attributes = new Map();
    this.children = [];
    this.parent = null;
    this.style = {};
    this.hidden = false;
    this.inert = false;
    this.textContent = '';
    this.focusCalls = 0;
    this.classes = new Set();
    this.classList = {
      add: (name) => this.classes.add(name),
      remove: (name) => this.classes.delete(name),
      contains: (name) => this.classes.has(name)
    };
    this.rect = { left: 40, right: 80, top: 20, bottom: 60, width: 40, height: 40 };
  }
  get isConnected() { return this.tag === 'document' || !!this.parent?.isConnected; }
  set innerHTML(_value) { throw new Error('Never use innerHTML for Scripture data'); }
  matches(selector) {
    const match = selector.match(/^(\w+)?\[([^\]]+)\]$/);
    assert.ok(match, `supported attribute selector: ${selector}`);
    return (!match[1] || this.tag === match[1]) && this.attributes.has(match[2]);
  }
  closest(selector) { return this.matches(selector) ? this : this.parent?.closest(selector) || null; }
  contains(target) { return this === target || this.children.some((child) => child.contains(target)); }
  querySelectorAll(selector) {
    return this.children.flatMap((child) => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
  append(child) { child.parent = this; this.children.push(child); return child; }
  remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
  getBoundingClientRect() { return this.rect; }
  focus() {
    this.focusCalls++;
    let root = this;
    while (root.parent) root = root.parent;
    const previous = root.activeElement;
    root.activeElement = this;
    if (previous && previous !== this) root.emit('focusout', previous, { relatedTarget: this });
    root.emit('focusin', this, { relatedTarget: previous });
  }
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const flush = () => new Promise((resolve) => setImmediate(resolve));

function harness({ fine = true, reduced = false, width = 1000, height = 800, matchMedia = true } = {}) {
  const document = new Element('document');
  document.body = document.append(new Element('body'));
  document.activeElement = document.body;
  const documentListeners = new Map();
  const windowListeners = new Map();
  const timers = new Map();
  const requests = [];
  const media = { matches: fine };
  const motion = { matches: reduced };
  let now = 0;
  let nextTimer = 0;
  const listen = (listeners, type, callback, capture = false) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push({ callback, capture });
  };
  document.addEventListener = (...args) => listen(documentListeners, ...args);
  document.getElementById = (id) => {
    const find = (element) => element.getAttribute('id') === id ? element : element.children.map(find).find(Boolean);
    return find(document) || null;
  };
  const context = vm.createContext({
    document, URL, AbortController, innerWidth: width, innerHeight: height,
    location: { href: 'https://example.test/reading' },
    matchMedia: matchMedia ? (query) => {
      assert.ok(['(hover: hover) and (pointer: fine)', '(prefers-reduced-motion: reduce)'].includes(query));
      return query.includes('reduced-motion') ? motion : media;
    } : undefined,
    addEventListener: (...args) => listen(windowListeners, ...args),
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { id, callback, due: now + delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
    fetch(url, options) {
      const pending = deferred();
      // Deliberately do not reject on abort: even an uncooperative response must stay stale.
      requests.push({ url, options, ...pending });
      return pending.promise;
    }
  });
  context.window = context;
  const emit = (type, target = document, extra = {}, onWindow = false) => {
    const event = { type, target, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; }, ...extra };
    for (const { callback } of (onWindow ? windowListeners : documentListeners).get(type) || []) callback(event);
    return event;
  };
  document.emit = emit;
  const marked = (parent, tag, name) => {
    const element = parent.append(new Element(tag));
    element.setAttribute(`data-b270-scripture-${name}`, '');
    return element;
  };
  const trigger = marked(document.body, 'button', 'trigger');
  trigger.setAttribute('data-b270-scripture-url', '/scripture_frame?locale=en');
  trigger.setAttribute('aria-controls', 'b270-scripture-frame');
  trigger.setAttribute('aria-expanded', 'false');
  const svg = trigger.append(new Element('svg'));
  const path = svg.append(new Element('path'));
  const secondPath = svg.append(new Element('path'));
  const popup = document.body.append(new Element('div'));
  popup.setAttribute('id', 'b270-scripture-frame');
  popup.hidden = true;
  popup.getBoundingClientRect = () => ({ width: Math.min(512, context.innerWidth - 24), height: Math.min(400, context.innerHeight - 24) });

  const status = marked(popup, 'p', 'status');
  const art = marked(popup, 'figure', 'art');
  art.hidden = true;
  const fields = Object.fromEntries(['reference', 'text', 'translation', 'attribution'].map((key) => [key, marked(art, 'span', key)]));
  const outside = document.body.append(new Element('input'));
  return {
    context, document, documentListeners, windowListeners, timers, requests, media, motion,
    trigger, svg, path, secondPath, popup, status, art, fields, outside,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit,
    over: (target = path, pointerType = 'mouse', relatedTarget = null) => emit('pointerover', target, { pointerType, relatedTarget }),
    out: (target = path, relatedTarget = null) => emit('pointerout', target, { pointerType: 'mouse', relatedTarget }),
    click: (target = trigger, extra = {}) => emit('click', target, { detail: 1, ...extra }),
    key: (key = 'Escape') => emit('keydown', document.activeElement, { key }),
    async reply(index = 0, value = frame, statusCode = 200) {
      requests[index].resolve({ status: statusCode, ok: statusCode >= 200 && statusCode < 300, json: async () => value });
      await flush();
    },
    advance(milliseconds) {
      const end = now + milliseconds;
      let executions = 0;
      while (true) {
        const timer = [...timers.values()].filter((value) => value.due <= end).sort((a, b) => a.due - b.due || a.id - b.id)[0];
        if (!timer) break;
        assert.ok(++executions < 100, 'bounded timer loop');
        now = timer.due;
        timers.delete(timer.id);
        timer.callback();
      }
      now = end;
    }
  };
}

function setup(options) {
  const h = harness(options);
  h.evaluate();
  return h;
}
function hoverOpen(h) { h.over(); h.advance(3000); }
function assertOpen(h, open = true) {
  assert.equal(h.trigger.getAttribute('aria-expanded'), String(open));
  assert.equal(h.popup.classList.contains('is-visible'), open);
}

test('nested SVG hover waits exactly 3000ms, preserves intent across descendants, and never steals focus', async () => {
  const h = setup();
  h.outside.focus();
  h.over();
  h.advance(1700);
  h.out(h.path, h.secondPath);
  h.over(h.secondPath, 'mouse', h.path);
  h.advance(1299);
  assert.equal(h.requests.length, 0);
  assert.equal(h.popup.hidden, true);
  h.advance(1);
  assert.equal(h.requests.length, 1);
  assertOpen(h);
  assert.equal(h.status.textContent, 'Loading Scripture frame…');
  assert.equal(h.popup.getAttribute('aria-busy'), 'true');
  assert.equal(h.document.activeElement, h.outside);
  assert.equal(h.popup.focusCalls, 0);
  assert.equal(h.requests[0].url, 'https://example.test/scripture_frame?locale=en');
  assert.equal(h.requests[0].options.headers.Accept, 'application/json');
  assert.equal(h.requests[0].options.credentials, 'same-origin');
  await h.reply();
  assert.equal(h.art.hidden, false);
  assert.equal(h.fields.text.textContent, frame.text);
  assert.equal(h.fields.reference.textContent, frame.reference);
  assert.equal(h.fields.translation.textContent, frame.translation);
  assert.equal(h.fields.attribution.hidden, true);
  assert.equal(h.status.hidden, true);
  assert.equal(h.popup.getAttribute('aria-busy'), 'false');
});

test('exiting pending intent cancels immediately; reentry requires a new full delay even if a stale timer fires', () => {
  const h = setup();
  h.over();
  const stale = [...h.timers.values()][0].callback;
  h.advance(2999);
  h.out();
  h.advance(5000);
  stale();
  assert.equal(h.requests.length, 0);
  h.over(h.svg);
  h.advance(2999);
  assert.equal(h.requests.length, 0);
  h.advance(1);
  assert.equal(h.requests.length, 1);
});

for (const pointerType of ['mouse', 'pen']) {
  for (const phase of ['pending', 'open']) {
    test(`Escape during ${phase} ${pointerType} hover ignores internal SVG transitions until genuine reentry`, async () => {
      const h = setup();
      h.over(h.path, pointerType);
      h.advance(phase === 'open' ? 3000 : 1000);
      if (phase === 'open') await h.reply();
      const count = h.requests.length;
      h.key();
      assertOpen(h, false);

      for (const [target, relatedTarget] of [[h.secondPath, h.path], [h.svg, h.secondPath], [h.trigger, h.svg], [h.path, h.trigger]]) {
        h.emit('pointerout', relatedTarget, { pointerType, relatedTarget: target });
        h.over(target, pointerType, relatedTarget);
        h.advance(75);
      }
      h.advance(5000);
      assert.equal(h.requests.length, count, 'internal movement cannot restart dismissed hover intent');
      assert.equal(h.popup.hidden, true);
      assert.equal(h.timers.size, 0);
      assertOpen(h, false);

      h.emit('pointerout', h.path, { pointerType, relatedTarget: h.outside });
      h.over(h.secondPath, pointerType, h.outside);
      h.advance(2999);
      assert.equal(h.requests.length, count, 'genuine reentry still requires the full hover delay');
      h.advance(1);
      assert.equal(h.requests.length, count + 1);
      assertOpen(h);
    });
  }
}

for (const [pointerType, fine, allowed] of [['mouse', true, true], ['pen', true, true], ['touch', true, false], ['mouse', false, false], ['pen', false, false], ['', true, false]]) {
  test(`hover eligibility: ${pointerType || 'unknown'}, fine=${fine}`, () => {
    const h = setup({ fine });
    h.over(h.path, pointerType);
    h.advance(10000);
    assert.equal(h.requests.length, Number(allowed));
  });
}

test('capability change, missing matchMedia, disconnected trigger, and unmarked targets do not request', () => {
  const changed = setup();
  changed.over();
  changed.media.matches = false;
  changed.advance(3000);
  assert.equal(changed.requests.length, 0);
  const missing = setup({ matchMedia: false });
  missing.over();
  missing.advance(3000);
  assert.equal(missing.requests.length, 0);
  const detached = setup();
  detached.over();
  detached.trigger.remove();
  detached.advance(3000);
  assert.equal(detached.requests.length, 0);
  const plain = setup();
  plain.over(plain.outside);
  plain.over({});
  plain.advance(3000);
  assert.equal(plain.requests.length, 0);
});

test('the 12px gap has a 220ms leave grace; popup and trigger reentry preserve the same response', async () => {
  const h = setup();
  hoverOpen(h);
  h.out();
  h.advance(219);
  assertOpen(h);
  h.over(h.popup, 'mouse', h.path);
  h.advance(1000);
  await h.reply();
  assertOpen(h);
  assert.equal(h.requests.length, 1);
  h.out(h.popup, h.art);
  h.over(h.art, 'mouse', h.popup);
  h.advance(1000);
  assertOpen(h);
  h.out(h.art);
  h.advance(100);
  h.over(h.path, 'mouse', h.outside);
  h.advance(500);
  assertOpen(h);
  h.out();
  h.advance(220);
  assertOpen(h, false);
  assert.equal(h.popup.hidden, false, 'fade is visible but noninteractive');
  assert.equal(h.popup.inert, true);
  assert.equal(h.popup.getAttribute('aria-hidden'), 'true');
  h.advance(180);
  assert.equal(h.popup.hidden, true);
});

test('departed requests abort and cannot replace a new frame, including a late JSON parse', async () => {
  const h = setup();
  hoverOpen(h);
  const json = deferred();
  h.requests[0].resolve({ status: 200, ok: true, json: () => json.promise });
  await flush();
  h.out();
  h.advance(220);
  assert.equal(h.requests[0].options.signal.aborted, true);
  h.over();
  h.advance(3000);
  await h.reply(1, { ...frame, id: 18, text: 'The newer frame' });
  json.resolve({ ...frame, text: 'Stale frame' });
  await flush();
  assertOpen(h);
  assert.equal(h.fields.text.textContent, 'The newer frame');
  h.key();
  h.click();
  assert.equal(new URL(h.requests[2].url).searchParams.get('exclude'), '18');
});

test('late fetch success and rejection cannot reopen or overwrite a newer request', async () => {
  for (const reject of [false, true]) {
    const h = setup();
    hoverOpen(h);
    h.key();
    h.click();
    if (reject) h.requests[0].reject(new Error('late network failure'));
    else await h.reply(0, { ...frame, text: 'obsolete' });
    await flush();
    assert.equal(h.status.getAttribute('data-state'), 'loading');
    assert.equal(h.art.hidden, true);
    await h.reply(1);
    assertOpen(h);
    assert.equal(h.fields.text.textContent, frame.text);
  }
});

test('mouse click opens immediately, pins across pointer exit, and the next click closes', () => {
  const h = setup();
  h.click(h.path);
  assert.equal(h.requests.length, 1);
  assertOpen(h);
  assert.equal(h.popup.focusCalls, 0);
  h.out();
  h.advance(10000);
  assertOpen(h);
  h.click(h.secondPath);
  assertOpen(h, false);
  assert.equal(h.requests[0].options.signal.aborted, true);
});

test('clicking hover-open pins rather than closing or fetching again; pending hover click opens now', () => {
  const h = setup();
  hoverOpen(h);
  h.click();
  h.out();
  h.advance(5000);
  assertOpen(h);
  assert.equal(h.requests.length, 1);
  h.click();
  assertOpen(h, false);
  const pending = setup();
  pending.over();
  pending.advance(1500);
  pending.click();
  assertOpen(pending);
  assert.equal(pending.requests.length, 1);
  pending.advance(5000);
  assert.equal(pending.requests.length, 1);
});

for (const activation of ['keyboard', 'touch', 'coarse']) {
  test(`${activation} activation focuses the nonmodal popup and selecting the bread again restores the trigger`, () => {
    const h = setup({ fine: activation !== 'coarse' });
    h.trigger.focus();
    if (activation === 'touch') h.emit('pointerdown', h.path, { pointerType: 'touch' });
    h.click(h.path, { detail: activation === 'keyboard' ? 0 : 1 });
    assertOpen(h);
    assert.equal(h.document.activeElement, h.popup);
    h.click(h.trigger, { detail: activation === 'keyboard' ? 0 : 1 });
    assertOpen(h, false);
    assert.equal(h.document.activeElement, h.trigger);
  });
}

test('Escape restores keyboard focus, but hover Escape never steals unrelated focus', () => {
  const keyboard = setup();
  keyboard.click(keyboard.trigger, { detail: 0 });
  assert.equal(keyboard.key().defaultPrevented, true);
  assert.equal(keyboard.document.activeElement, keyboard.trigger);
  assertOpen(keyboard, false);
  const hover = setup();
  hover.outside.focus();
  hoverOpen(hover);
  hover.key();
  assert.equal(hover.document.activeElement, hover.outside);
  assert.equal(hover.trigger.focusCalls, 0);
});

test('pointer dismissal suppresses the bread focus outline until keyboard interaction resumes', () => {
  for (const pointerType of ['mouse', 'touch', 'pen']) {
    const h = setup();
    h.emit('pointerdown', h.path, { pointerType });
    h.click(h.path, { pointerType });
    assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), '');
    h.click(h.path, { pointerType });
    assertOpen(h, false);
    assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), '', 'pointer dismissal keeps the bright focus outline suppressed');
    h.key('Tab');
    assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), null, 'keyboard navigation restores normal focus visibility');
  }
});

for (const pointerType of ['mouse', 'touch', 'pen']) {
  test(`${pointerType} open then Escape keeps pointer focus suppressed without blurring; keyboard activation restores it`, () => {
    for (const activation of ['Enter', ' ']) {
      const h = setup();
      h.emit('pointerdown', h.path, { pointerType });
      h.trigger.focus();
      h.click(h.path, { pointerType });
      assert.equal(h.key().defaultPrevented, true);
      assertOpen(h, false);
      assert.equal(h.document.activeElement, h.trigger, 'dismissal retains or restores focus');
      assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), '', 'Escape is dismissal, not keyboard activation');
      assert.equal(h.key().defaultPrevented, false);
      assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), '', 'repeated Escape while closed cannot leave a ring');
      h.key(activation);
      assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), null, 'real keyboard activation restores the focus indicator');
      h.click(h.trigger, { detail: 0 });
      assert.equal(h.document.activeElement, h.popup);
      h.key();
      assertOpen(h, false);
      assert.equal(h.document.activeElement, h.trigger);
      assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), null, 'keyboard-open then Escape retains visible focus');
    }
  });
}

test('Tab after pointer-open then Escape restores normal focus visibility', () => {
  const h = setup();
  h.emit('pointerdown', h.path, { pointerType: 'touch' });
  h.click(h.path, { pointerType: 'touch' });
  h.key();
  h.key('Tab');
  assert.equal(h.trigger.getAttribute('data-b270-scripture-pointer-focus'), null);
});

test('native Enter/Space activation is not doubled or prevented by a second handler', () => {
  for (const key of ['Enter', ' ']) {
    const h = setup();
    h.trigger.focus();
    assert.equal(h.key(key).defaultPrevented, false);
    assert.equal(h.requests.length, 0, 'browser owns native button activation');
    h.click(h.trigger, { detail: 0 });
    assert.equal(h.requests.length, 1);
    assert.equal(h.document.activeElement, h.popup);
  }
});

test('focus can move freely within the region; leaving closes without stealing focus', () => {
  const h = setup();
  h.click(h.trigger, { detail: 0 });
  h.trigger.focus();
  assertOpen(h);
  h.popup.focus();
  assertOpen(h);
  h.trigger.focus();
  assertOpen(h);
  assert.equal(h.key('Tab').defaultPrevented, false);
  h.outside.focus();
  assertOpen(h, false);
  assert.equal(h.document.activeElement, h.outside);
  const unknown = setup();
  unknown.click(unknown.trigger, { detail: 0 });
  unknown.emit('focusout', unknown.popup, { relatedTarget: null });
  unknown.document.activeElement = unknown.outside;
  unknown.advance(0);
  assertOpen(unknown, false);
  assert.equal(unknown.trigger.focusCalls, 0);
});

test('outside pointerdown and synthetic outside click dismiss without preventing the outside action', () => {
  for (const type of ['pointerdown', 'click']) {
    const h = setup();
    h.click(h.trigger, { detail: 0 });
    const event = h.emit(type, h.outside, { pointerType: 'mouse' });
    assert.equal(event.defaultPrevented, false);
    assertOpen(h, false);
    assert.equal(h.trigger.focusCalls, 0);
  }
});

for (const [type, onWindow, immediate] of [['scroll', false, false], ['resize', true, false], ['pagehide', true, true], ['turbo:before-cache', false, true], ['turbo:before-render', false, true]]) {
  test(`${type} cancels both pending intent and in-flight work with no late reappearance`, async () => {
    const h = setup();
    h.over();
    h.emit(type, h.document, {}, onWindow);
    h.advance(4000);
    assert.equal(h.requests.length, 0);
    hoverOpen(h);
    h.emit(type, h.document, {}, onWindow);
    assertOpen(h, false);
    assert.equal(h.requests[0].options.signal.aborted, true);
    if (immediate) assert.equal(h.popup.hidden, true);
    await h.reply();
    h.advance(4000);
    assert.equal(h.popup.hidden, true);
    assert.equal(h.art.hidden, true);
    assert.equal(h.timers.size, 0);
  });
}

test('scrolling a long verse inside the popup does not dismiss it', () => {
  const h = setup();
  hoverOpen(h);
  h.emit('scroll', h.art);
  h.emit('scroll', h.fields.text);
  assertOpen(h);
  assert.equal(h.documentListeners.get('scroll')[0].capture, true);
});

test('Turbo script reevaluation resets old state and never duplicates delegated handlers', async () => {
  const h = setup();
  const singleton = h.context.Bible270ScriptureFrame;
  h.click();
  h.evaluate();
  h.evaluate();
  assert.equal(h.context.Bible270ScriptureFrame, singleton);
  assert.equal(h.popup.hidden, true);
  assert.equal(h.requests[0].options.signal.aborted, true);
  for (const listeners of [...h.documentListeners.values(), ...h.windowListeners.values()]) assert.equal(listeners.length, 1);
  await h.reply();
  assert.equal(h.popup.hidden, true);
  h.click();
  assert.equal(h.requests.length, 2);
  assertOpen(h);
  h.context.Bible270ScriptureFrame.reset();
  assert.equal(h.popup.hidden, true);
});

test('204, HTTP errors, invalid JSON bodies, parse failures and network errors have accessible recoverable status', async () => {
  for (const kind of ['empty', 'http', 'invalid', 'parse', 'network']) {
    const h = setup();
    h.click();
    if (kind === 'network') h.requests[0].reject(new Error('offline'));
    else if (kind === 'parse') h.requests[0].resolve({ status: 200, ok: true, json: async () => { throw new Error('bad JSON'); } });
    else await h.reply(0, kind === 'invalid' ? { text: '<b>oops</b>' } : frame, kind === 'empty' ? 204 : kind === 'http' ? 500 : 200);
    await flush();
    assertOpen(h);
    assert.equal(h.status.getAttribute('data-state'), kind === 'empty' ? 'empty' : 'error');
    assert.equal(h.popup.getAttribute('aria-busy'), 'false');
    assert.equal(h.art.hidden, true);
    assert.equal(h.status.hidden, false);
    h.click();
    h.click();
    await h.reply(1);
    assert.equal(h.art.hidden, false);
  }
});

test('JSON strings are assigned only as literal text; newlines, reference, translation and optional attribution survive', async () => {
  const h = setup();
  const hostile = { id: 'a&b/17', reference: '<img src=x onerror=alert(1)>', text: '<script>alert(1)</script>\n& "quoted"', translation: '<b>NASB95</b>', attribution: '<svg onload=alert(1)>' };
  h.click();
  await h.reply(0, hostile);
  for (const key of ['reference', 'text', 'translation', 'attribution']) assert.equal(h.fields[key].textContent, hostile[key]);
  assert.equal(h.fields.attribution.hidden, false);
  h.click();
  h.click();
  const url = new URL(h.requests[1].url);
  assert.equal(url.searchParams.get('exclude'), hostile.id);
  assert.equal(url.searchParams.get('locale'), 'en');
  await h.reply(1, { ...frame, attribution: null });
  assert.equal(h.fields.attribution.textContent, '');
  assert.equal(h.fields.attribution.hidden, true);
});

test('popup positions below the trigger with a 12px gap and clamps to small viewport edges', async () => {
  const h = setup();
  hoverOpen(h);
  assert.equal(h.popup.style.left, '40px');
  assert.equal(h.popup.style.top, '72px');
  const small = setup({ width: 280, height: 260 });
  small.trigger.rect = { left: 260, bottom: 250 };
  small.click();
  await small.reply();
  assert.equal(small.popup.style.left, '12px');
  assert.equal(small.popup.style.top, '12px');
});

test('reduced motion hides immediately without scheduling a fade', () => {
  const h = setup({ reduced: true });
  h.click();
  h.key();
  assert.equal(h.popup.hidden, true);
  assert.equal(h.timers.size, 0);
});

test('markup exposes the reusable escaped figure, real separate button, nonmodal dialog and scoped responsive art styles', () => {
  const header = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_header.html.erb'), 'utf8');
  const figure = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_scripture_frame.html.erb'), 'utf8');
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  assert.match(header, /unless Bible270\.config\.header_mark == false/);
  assert.match(header, /<button type="button"[^>]*data-b270-scripture-trigger/);
  assert.match(header, /data-b270-scripture-url="<%= scripture_frame_path %>"/);
  assert.match(header, /aria-label="Show a Scripture frame" aria-controls="b270-scripture-frame" aria-expanded="false"/);
  assert.ok(header.indexOf('</button>') < header.indexOf('link_to root_path'), 'mark is not inside the home anchor');
  assert.match(header, /<%= b270_mark\(size: 34\) %>/, 'custom image support stays with the existing helper');
  assert.match(markup, /id="b270-scripture-frame"[^>]*role="dialog" aria-modal="false"/);
  assert.match(markup, /aria-label="Scripture frame" tabindex="-1" hidden/);
  assert.match(markup, /data-b270-scripture-status role="status" aria-live="polite"/);
  assert.doesNotMatch(markup, /data-b270-scripture-close|b270-scripture-popup__tools|Close Scripture frame/);
  assert.match(styles, /\.b270-scripture-trigger\[data-b270-scripture-pointer-focus\]:focus\{outline:none\}/);
  assert.doesNotMatch(styles, /\.b270-scripture-trigger:hover/);
  assert.match(styles, /\.b270-scripture-trigger\[aria-expanded="true"\]\{border-color:var\(--line\);background:var\(--card\)\}/);
  assert.match(styles, /:focus-visible\{outline:2px solid var\(--gold\)/);
  assert.match(figure, /local_assigns\[:frame\]/);
  for (const key of ['text', 'reference', 'translation', 'attribution']) assert.match(figure, new RegExp(`h\\(value\\.call\\(:${key}\\)\\)`));
  assert.doesNotMatch(source, /innerHTML|insertAdjacentHTML/);
  assert.doesNotMatch(figure + markup, /https?:\/\/|copyright|©/i);
  assert.match(styles, /\.b270-scripture-art__verse[^}]*"Spectral"/);
  assert.match(styles, /\.b270-scripture-art__verse p\{[^}]*white-space:pre-wrap/);
  assert.match(styles, /\.b270-scripture-popup>\.b270-scripture-art\{[^}]*overflow-y:auto/);
  assert.match(styles, /width:min\(32rem,calc\(100vw - 24px\)\)/);
  assert.match(styles, /max-height:calc\(100dvh - 24px\)/);
  assert.match(styles, /prefers-reduced-motion:reduce\)\{\s*\.b270-scripture-popup\{transition:none\}/);
  assert.match(styles, /\.b270-brand\{[^}]*flex-wrap:wrap/);
  assert.match(styles, /\.b270-brandlink\{display:flex;align-items:center;/);
  assert.match(styles, /\.b270-brand-home\{display:flex;align-items:center;/);
  assert.match(styles, /\.b270-scripture-trigger > img\.b270-mark\{[^}]*width:34px;height:34px/);
  assert.match(styles, /\.b270-scripture-trigger \.b270-mark svg > rect\{fill:var\(--card\);stroke:none\}/);
  assert.doesNotMatch(styles, /\.b270-scripture-trigger[^{}]*path\s*\{/);
});

test('translation and attribution are per entry, including NKJV rather than a fixed default label', async () => {
  const h = setup();
  h.click();
  await h.reply(0, { ...frame, reference: 'Hebrews 4:12', translation: 'NKJV', attribution: 'Entry-provided attribution' });
  assert.equal(h.fields.translation.textContent, 'NKJV');
  assert.equal(h.fields.reference.textContent, 'Hebrews 4:12');
  assert.equal(h.fields.attribution.textContent, 'Entry-provided attribution');
});

test('mobile header fits, icon/title centers align, theme changes only the board, and long art scrolls (optional Chromium)', { timeout: 20000 }, (t) => {
  const { spawnSync } = require('node:child_process');
  const probe = spawnSync('chromium', ['--version'], { timeout: 3000, encoding: 'utf8' });
  if (probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; VM and static checks still run');
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  const favicon = readFileSync(resolve(__dirname, '../../lib/bible270/favicon.rb'), 'utf8');
  const svg = favicon.match(/SVG = <<~SVG\n([\s\S]*?)^\s*SVG/m)[1].replace(/%23/g, '#');
  const figure = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_scripture_frame.html.erb'), 'utf8').replace(/<%[\s\S]*?%>/g, '');
  const scenery = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_theme_scenery.html.erb'), 'utf8');
  const papyrus = scenery.match(/<svg class="b270-theme-scenery" data-scenery="light"[\s\S]*?<\/svg>/)[0].replace(/<%[\s\S]*?%>/g, '');
  // Exercise the actual stylesheet in isolated viewports, without Rails, fonts, network or dependencies.
  const librarySource = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_scripture_library_ui.html.erb'), 'utf8')
    .replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
  const browserCheck = function(styles, svg, figure, papyrus, librarySource) {
    const failures = [];
    const fills = new Set();
    const surfaces = new Set();
    const boards = [];
    const check = (condition, message) => { if (!condition) failures.push(message); };
    const widths = [240, 280, 320, 360, 390, 480, 600, 601, 768, 820, 821, 1024, 1100, 1101];
    for (const width of widths) {
      for (const mark of ['inline', 'image', 'none']) {
        const viewport = document.createElement('iframe');
        viewport.style.cssText = `display:block;border:0;width:${width}px;height:600px`;
        document.body.append(viewport);
        const doc = viewport.contentDocument;
        const icon = mark === 'inline' ? `<span class="b270-mark">${svg}</span>` : `<img class="b270-mark" alt="" src="data:image/svg+xml,${encodeURIComponent(svg)}">`;
        const button = mark === 'none' ? '' : `<button class="b270-scripture-trigger" type="button">${icon}</button>`;
        doc.open();
        doc.write(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head>
          <body class="b270" data-display-mode="light">${papyrus}<div class="b270-wrap"><header class="b270-topbar">
          <div class="b270-brand"><div class="b270-brand-home">${button}<a class="b270-brandlink" href="#"><span class="b270-title">A very long Bible reading application title</span></a></div>
          <form class="b270-header-theme"><span class="b270-select-wrap b270-select-wrap--compact"><select class="b270-header-theme-select"><option>Dark green</option></select></span></form></div>
          <nav class="b270-nav"><div class="b270-desktopnav"><a href="#">Overview</a><a href="#">Community</a><a href="#">Profile</a></div>
          <div class="b270-navmenu"><button type="button" class="b270-navtoggle">☰</button></div></nav></header>
          <details class="b270-index b270-alumni" id="b270-alumni"><summary>Show Alumni</summary><div class="b270-list">Reader</div></details>
          <section class="b270-panel" id="b270-scripture-frames"><details class="b270-scripture-library-disclosure"><summary>Sample passage · NKJV · Custom</summary><blockquote class="b270-scripture-library-text">Sample Scripture text.</blockquote></details>
                    <article class="b270-scripture-library-entry b270-scripture-library-entry--default"><details class="b270-scripture-library-disclosure"><summary>A long default reference · NASB95 · Default · Disabled</summary><blockquote class="b270-scripture-library-text">Default passage.</blockquote></details><form class="b270-scripture-default-toggle"><button type="submit" class="b270-linkbtn">Enable</button></form></article></section></div>
          <div class="b270-scripture-popup is-visible" style="left:12px;top:12px">${figure}</div></body></html>`);
        doc.close();
        viewport.contentWindow.Function(librarySource)();
        const name = `${width}px/${mark}`;
        const defaultRow = doc.querySelector('.b270-scripture-library-entry--default');
        const defaultToggle = defaultRow.querySelector('form').getBoundingClientRect();
        const defaultHeading = defaultRow.querySelector('details').getBoundingClientRect();
        check(Math.abs(defaultToggle.right - defaultRow.getBoundingClientRect().right) < 1, `${name}: default toggle aligns to the right`);
        check(defaultHeading.right <= defaultToggle.left && Math.abs(defaultHeading.top - defaultToggle.top) < 1, `${name}: default toggle sits beside the heading without overlap`);
        const title = doc.querySelector('.b270-title').getBoundingClientRect();
        const trigger = doc.querySelector('.b270-scripture-trigger');
        const brand = doc.querySelector('.b270-brand-home').getBoundingClientRect();
        const brandStart = trigger ? trigger.getBoundingClientRect().left : title.left;
        check(Math.abs(brandStart - brand.left - (width <= 820 ? 12 : 0)) < 0.5, `${name}: compact brand clears the parchment corner, desktop stays unchanged`);
        if (trigger) {
          const icon = trigger.querySelector('svg,img').getBoundingClientRect();
          check(Math.abs(icon.width - 34) < 0.1 && Math.abs(icon.height - 34) < 0.1, `${name}: 34px icon`);
          check(Math.abs((icon.top + icon.bottom) / 2 - (title.top + title.bottom) / 2) < 0.5, `${name}: center alignment`);
          const corner = doc.querySelector('use.b270-papyrus-corner').getBoundingClientRect();
          check(corner.right <= icon.left || corner.bottom <= icon.top, `${name}: bread clears the actual parchment corner and shadow (corner ${corner.right},${corner.bottom}; icon ${icon.left},${icon.top})`);
          const cornerScale = width <= 820 ? 0.35 : width <= 1100 ? 0.4 : 1;
          const transform = viewport.contentWindow.getComputedStyle(doc.querySelector('use.b270-papyrus-corner')).transform;
          check(transform === (cornerScale === 1 ? 'none' : `matrix(${cornerScale}, 0, 0, ${cornerScale}, 0, 0)`), `${name}: corner shrinks before crowding the header`);
          trigger.setAttribute('aria-expanded', 'true');
          const openBorder = viewport.contentWindow.getComputedStyle(trigger).borderTopColor;
          check(openBorder !== 'rgba(0, 0, 0, 0)', `${name}: open frame has a subtle trigger border`);
          trigger.setAttribute('aria-expanded', 'false');
          check(viewport.contentWindow.getComputedStyle(trigger).borderTopColor === 'rgba(0, 0, 0, 0)', `${name}: dismissed frame leaves no trigger border`);
          trigger.focus();
          trigger.setAttribute('data-b270-scripture-pointer-focus', '');
          check(viewport.contentWindow.getComputedStyle(trigger).outlineStyle === 'none', `${name}: pointer focus has no bright outline`);
          trigger.removeAttribute('data-b270-scripture-pointer-focus');
          trigger.focus({ focusVisible: true });
          check(viewport.contentWindow.getComputedStyle(trigger).outlineWidth === '2px', `${name}: keyboard focus indicator is retained (${viewport.contentWindow.getComputedStyle(trigger).outlineWidth}; focused ${doc.activeElement === trigger}; visible ${trigger.matches(':focus-visible')})`);
        }
        const alumni = doc.querySelector('#b270-alumni');
        const library = doc.querySelector('#b270-scripture-frames');
        for (const open of [false, true]) {
          alumni.open = open;
          const gap = library.getBoundingClientRect().top - alumni.getBoundingClientRect().bottom;
          check(gap >= 24, `${name}: ${open ? 'expanded' : 'collapsed'} alumni leaves space before Scripture frames`);
        }
        alumni.open = false;
        check(doc.documentElement.scrollWidth <= doc.documentElement.clientWidth, `${name}: horizontal page overflow`);
        const nav = doc.querySelector('.b270-nav').getBoundingClientRect();
        check(nav.right <= width && title.right <= nav.left, `${name}: header fits without navigation overlap`);
        const text = doc.querySelector('[data-b270-scripture-text]');
        text.textContent = 'A long verse with preserved newlines.\n'.repeat(200);
        const art = doc.querySelector('.b270-scripture-art');
        const popup = doc.querySelector('.b270-scripture-popup').getBoundingClientRect();
        check(popup.right <= width && popup.bottom <= 600, `${name}: popup viewport bounds`);
        check(art.scrollHeight > art.clientHeight, `${name}: long verse scroll area`);
        art.scrollTop = 50;
        check(art.scrollTop === 50, `${name}: long verse is scrollable`);
        if (mark === 'inline' && width === 320) {
          for (const theme of ['light', 'sage', 'mist', 'dark', 'dark_green', 'dark_blue']) {
            doc.body.setAttribute('data-display-mode', theme);
            const rect = trigger.querySelector('rect');
            const path = trigger.querySelector('path');
            const board = viewport.contentWindow.getComputedStyle(rect);
            const loaf = viewport.contentWindow.getComputedStyle(path);
            fills.add(board.fill);
            boards.push({ theme, fill: board.fill, stroke: board.stroke });
            check(board.stroke === 'none', `${theme}: closed bread board has no decorative border`);
            check(loaf.fill === 'rgb(198, 162, 74)', `${theme}: loaf stays warm gold`);
            const palette = viewport.contentWindow.getComputedStyle(doc.body);
            const swatch = doc.createElement('span');
            swatch.style.color = palette.getPropertyValue('--card');
            doc.body.append(swatch);
            check(board.fill === viewport.contentWindow.getComputedStyle(swatch).color, `${theme}: board uses theme card`);
            swatch.style.backgroundColor = theme === 'sage' ? '#d1e2ea' : 'color-mix(in srgb,var(--card) 90%,var(--gold))';
            const expectedSurface = viewport.contentWindow.getComputedStyle(swatch).backgroundColor;
            const mat = viewport.contentWindow.getComputedStyle(doc.querySelector('.b270-scripture-art__mat'));
            const shell = viewport.contentWindow.getComputedStyle(doc.querySelector('.b270-scripture-popup'));
            check(mat.backgroundColor === expectedSurface, `${theme}: mat uses a tinted theme surface`);
            check(shell.backgroundColor === expectedSurface, `${theme}: popup uses the same tinted surface`);
            const libraryText = doc.querySelector('.b270-scripture-library-text');
            const libraryDisclosure = libraryText.parentElement;
            const libraryStyle = viewport.contentWindow.getComputedStyle(libraryText);
            check(libraryStyle.backgroundColor === expectedSurface, `${theme}: tooltip surface follows the theme and differs from its panel`);
            libraryDisclosure.open = true;
            check(viewport.contentWindow.getComputedStyle(libraryText).position === 'relative', `${theme}: expanded passage takes space in the list`);
            check(viewport.contentWindow.getComputedStyle(libraryText).backgroundColor === expectedSurface, `${theme}: expanded text retains its distinct surface`);
            libraryDisclosure.open = false;
            const attribution = viewport.contentWindow.getComputedStyle(doc.querySelector('.b270-scripture-art__attribution'));
            swatch.style.color = palette.getPropertyValue('--muted');
            check(attribution.color === viewport.contentWindow.getComputedStyle(swatch).color, `${theme}: credit stays readable`);
            surfaces.add(mat.backgroundColor);
            swatch.remove();
          }
        }
        // Run native click/focus checks last so they cannot change input modality for the header checks.
        if (width === widths[widths.length - 1] && mark === 'none' && viewport.contentWindow.CSS.supports('selector(details::details-content)')) {
          const outside = doc.createElement('button');
          doc.body.append(outside);
          doc.querySelectorAll('.b270-scripture-library-disclosure').forEach((disclosure) => {
            const summary = disclosure.querySelector('summary');
            const text = disclosure.querySelector('.b270-scripture-library-text');
            disclosure.open = true;
            summary.focus();
            summary.click();
            check(!disclosure.open && viewport.contentWindow.getComputedStyle(text).display === 'none', `${name}: collapsing hides the passage even while its heading retains focus`);
            outside.focus();
            summary.focus();
            check(viewport.contentWindow.getComputedStyle(text).display === 'block', `${name}: fresh heading focus restores the tooltip (dismissed ${disclosure.hasAttribute('data-b270-scripture-preview-dismissed')}; active ${doc.activeElement === summary}; focus-within ${disclosure.matches(':focus-within')})`);
          });
          outside.remove();
        }
        viewport.remove();
      }
    }
    check(fills.size === 6, 'all six theme boards have distinct palette colours');
    check(surfaces.size === 6, 'all six Scripture frame surfaces follow their theme');
    const result = document.createElement('pre');
    result.id = 'result';
    result.textContent = JSON.stringify({ failures, scenarios: widths.length * 3, boards });
    document.body.append(result);
  };
  const page = `<!doctype html><html><body><script>(${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(svg)},${JSON.stringify(figure)},${JSON.stringify(papyrus)},${JSON.stringify(librarySource)})</script></body></html>`;
  const result = spawnSync('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--dump-dom', '--timeout=10000', '--virtual-time-budget=1000', `data:text/html,${encodeURIComponent(page)}`], {
    timeout: 15000, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024
  });
  assert.equal(result.status, 0, result.stderr || String(result.error));
  const output = result.stdout.match(/<pre id="result">([^<]*)<\/pre>/);
  assert.ok(output, 'browser completed all layout checks');
  const report = JSON.parse(output[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));
  assert.deepEqual(report.failures, [], JSON.stringify(report.failures, null, 2));
  assert.equal(report.scenarios, 42);
});
