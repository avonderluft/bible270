const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_day_completion_ui.html.erb');
const markup = readFileSync(filename, 'utf8');
const source = markup.replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const flightClass = 'b270-completion-dove-active';
const storageKey = (id) => `b270-completion-dove:${id}`;

class Element {
  constructor(tag, mutate, effects) {
    this.tag = tag;
    this.nodeType = tag === 'document' ? 9 : 1;
    this.attributes = new Map();
    this.children = [];
    this.parent = null;
    this.classes = new Set();
    this.focusCalls = 0;
    this.layoutReads = 0;
    this.rect = { width: 600, height: 400, top: 0, bottom: 400 };
    this.mutate = mutate;
    this.effects = effects;
    this._hidden = false;
    this._text = '';
    this.dataset = new Proxy({}, {
      get: (_target, key) => this.getAttribute(`data-${key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`) ?? undefined,
      set: (_target, key, value) => {
        this.setAttribute(`data-${key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`, value);
        return true;
      }
    });
    this.classList = {
      add: (name) => { this.effects.push(['class:add', this, name]); this.classes.add(name); },
      remove: (name) => { this.effects.push(['class:remove', this, name]); this.classes.delete(name); },
      contains: (name) => this.classes.has(name)
    };
  }
  get isConnected() { return this.tag === 'document' || !!this.parent?.isConnected; }
  get hidden() { return this._hidden; }
  set hidden(value) { this.effects.push(['hidden', this, value]); this._hidden = value; }
  get textContent() { return this._text || this.children.map((child) => child.textContent).join(''); }
  set textContent(_value) { assert.fail('Completion JavaScript must not rewrite server-rendered text'); }
  set innerHTML(_value) { assert.fail('Completion JavaScript must not replace server-rendered HTML'); }
  set innerText(_value) { assert.fail('Completion JavaScript must not rewrite server-rendered text'); }
  matches(selector) {
    const match = selector.match(/^\[([^\]]+)\]$/);
    assert.ok(match, `supported attribute selector: ${selector}`);
    return this.attributes.has(match[1]);
  }
  contains(node) { return this === node || this.children.some((child) => child.contains?.(node)); }
  querySelectorAll(selector) {
    return this.children.flatMap((child) => child.nodeType === 1
      ? [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)] : []);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  setAttribute(name, value) { this.effects.push(['attribute:set', this, name, value]); this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.effects.push(['attribute:remove', this, name]); this.attributes.delete(name); }
  appendChild(child) {
    child.remove();
    child.parent = this;
    this.children.push(child);
    this.effects.push(['append', this, child]);
    this.mutate(this, [child], []);
    return child;
  }
  remove() {
    if (!this.parent) return;
    const parent = this.parent;
    parent.children.splice(parent.children.indexOf(this), 1);
    this.parent = null;
    this.effects.push(['remove', parent, this]);
    this.mutate(parent, [], [this]);
  }
  getBoundingClientRect() { this.layoutReads++; return this.rect; }
  focus() {
    this.focusCalls++;
    let root = this;
    while (root.parent) root = root.parent;
    root.activeElement = this;
  }
}

function harness({ reduced = false, matchMedia = true, storage = new Map(), storageThrows,
  frame = true, dove = true, eventId = 'completion-1', long = false } = {}) {
  const effects = [];
  const observers = [];
  const mutate = (target, addedNodes, removedNodes) => {
    for (const observer of observers) {
      if (observer.target?.contains(target)) observer.records.push({ type: 'childList', target, addedNodes, removedNodes });
    }
  };
  const element = (tag = 'div') => new Element(tag, mutate, effects);
  const document = element('document');
  document.documentElement = document.appendChild(element('html'));
  document.body = document.documentElement.appendChild(element('body'));
  const container = document.body.appendChild(element('turbo-frame'));
  const outside = document.body.appendChild(element('input'));
  outside.focus();
  const documentListeners = new Map();
  const windowListeners = new Map();
  const timers = new Map();
  const rafs = new Map();
  const requests = [];
  const storageCalls = [];
  const motion = { matches: reduced };
  let now = 0;
  let nextId = 0;
  const listen = (listeners, type, callback) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push(callback);
  };
  document.addEventListener = (...args) => listen(documentListeners, ...args);
  const context = vm.createContext({
    document,
    Node: { ELEMENT_NODE: 1 },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; this.records = []; observers.push(this); }
      observe(target, options) { this.target = target; this.options = options; }
    },
    matchMedia: matchMedia ? (query) => {
      assert.equal(query, '(prefers-reduced-motion: reduce)');
      return motion;
    } : undefined,
    addEventListener: (...args) => listen(windowListeners, ...args),
    setTimeout(callback, delay) {
      const id = ++nextId;
      timers.set(id, { id, callback, due: now + delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
    requestAnimationFrame(callback) { const id = ++nextId; rafs.set(id, callback); return id; },
    cancelAnimationFrame: (id) => rafs.delete(id),
    fetch(...args) { requests.push(args); assert.fail('Completion must not fetch Scripture or other content'); }
  });
  const sessionStorage = {
    getItem(key) {
      storageCalls.push(['get', key]);
      if (storageThrows === 'get') throw new Error('Storage reads blocked');
      return storage.get(key) ?? null;
    },
    setItem(key, value) {
      storageCalls.push(['set', key, value]);
      if (storageThrows === 'set') throw new Error('Storage writes blocked');
      storage.set(key, value);
    }
  };
  Object.defineProperty(context, 'sessionStorage', { get() {
    if (storageThrows === 'access') throw new Error('Storage unavailable');
    return sessionStorage;
  } });
  context.window = context;
  const emit = (type, target = document, extra = {}, onWindow = false) => {
    const event = { type, target, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; }, ...extra };
    for (const callback of (onWindow ? windowListeners : documentListeners).get(type) || []) callback(event);
    return event;
  };
  const marked = (parent, name) => {
    const child = parent.appendChild(element());
    child.setAttribute(`data-b270-completion${name ? `-${name}` : ''}`, '');
    return child;
  };
  const makeCompletion = (id = eventId, options = {}) => {
    const root = marked(options.parent || container, '');
    if (id !== null) root.setAttribute('data-b270-completion-event', id);
    root.setAttribute('data-b270-day', '27');
    root.setAttribute('data-turbo-temporary', '');
    root.hidden = true;
    root.setAttribute('aria-hidden', 'true');
    const board = (options.frame ?? frame) ? marked(root, 'frame') : null;
    const fields = [];
    if (board) {
      board.setAttribute('role', 'region');
      board.setAttribute('aria-label', 'Day 27 completion Scripture');
      for (const text of ['Psalm 23:1', 'The LORD is my shepherd,\nI shall not want. <script>literal text</script>', 'NASB95', 'Translation attribution']) {
        const field = board.appendChild(element('span'));
        field._text = text;
        fields.push(field);
      }
      if (options.long ?? long) {
        fields[1]._text = `${fields[1]._text}\n`.repeat(1000);
        root.rect = { width: 600, height: 24000, top: 0, bottom: 24000 };
      }
    }
    const bird = (options.dove ?? dove) ? marked(root, 'dove') : null;
    const artwork = bird ? bird.appendChild(element('svg')) : null;
    const path = artwork ? artwork.appendChild(element('path')) : null;
    return { root, frame: board, dove: bird, path, fields, texts: fields.map((field) => field.textContent) };
  };
  const initial = makeCompletion();
  return {
    context, document, documentListeners, windowListeners, timers, rafs, requests, storage, storageCalls,
    observers, effects, motion, container, outside, element, makeCompletion, ...initial,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit,
    animation: (type = 'animationend', target = initial.dove, animationName = 'b270-dove-flight') => emit(type, target, { animationName }),
    key: (key = 'Escape') => emit('keydown', document.activeElement, { key }),
    flushMutations() {
      let deliveries = 0;
      while (observers.some((observer) => observer.records.length)) {
        assert.ok(++deliveries < 100, 'bounded mutation deliveries, including root reparenting');
        for (const observer of observers) {
          const records = observer.records.splice(0);
          if (records.length) observer.callback(records);
        }
      }
    },
    paint() {
      const callbacks = [...rafs.values()];
      rafs.clear();
      for (const callback of callbacks) callback(now);
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
  h.flushMutations();
  return h;
}
function visible(root, expected = true) { assert.equal(root.classList.contains('is-visible'), expected); }
function flying(dove, expected = true) { assert.equal(dove.classList.contains(flightClass), expected); }
function idle(h) { assert.equal(h.timers.size, 0); assert.equal(h.rafs.size, 0); }
function untouched(h, completion = h) {
  assert.deepEqual(completion.fields.map((field) => field.textContent), completion.texts);
  assert.equal(h.requests.length, 0);
  assert.equal(h.document.activeElement, h.outside);
  assert.equal(h.outside.focusCalls, 1);
  for (const node of [completion.root, completion.frame, completion.dove, ...completion.fields].filter(Boolean)) assert.equal(node.focusCalls, 0);
}
function startFlight(h) {
  h.paint();
  h.advance(6800);
  flying(h.dove);
  assert.equal(h.root.classList.contains('is-flying'), true);
}
function disposed(h, root = h.root) {
  assert.equal(root.isConnected, false, 'the entire sequence is disposed without a post-flight fade');
  assert.equal(root.parent, null);
  for (const child of root.children) assert.equal(child.isConnected, false);
  idle(h);
}
function beginManualFade(h) {
  h.key();
  visible(h.root, false);
  assert.equal(h.root.isConnected, true);
  assert.equal(h.root.classList.contains('is-flying'), false);
  assert.equal(h.timers.size, 1, 'manual finish keeps exactly one fade timer');
}
function finishFade(h, root = h.root) {
  visible(root, false);
  assert.equal(root.classList.contains('is-flying'), false, 'manual/no-dove fade cancels the delayed flight animation');
  assert.equal(root.getAttribute('aria-hidden'), 'true');
  assert.equal(root.isConnected, true);
  h.advance(199);
  assert.equal(root.isConnected, true);
  h.advance(1);
  assert.equal(root.isConnected, false);
  idle(h);
}

test('moves the existing root to body, unhides before rAF, then waits the full 1300ms fade plus 5500ms before flight', () => {
  const h = setup();
  assert.equal(h.root.parent, h.document.body);
  assert.equal(h.container.children.length, 0);
  assert.equal(h.root.hidden, false);
  assert.equal(h.root.getAttribute('aria-hidden'), null);
  assert.equal(h.root.dataset.b270CompletionInitialized, 'true');
  assert.equal(h.root.layoutReads, 1);
  assert.equal(h.root.querySelector('[data-b270-completion-frame]'), h.frame);
  assert.equal(h.root.querySelector('[data-b270-completion-dove]'), h.dove);
  visible(h.root, false);
  flying(h.dove, false);
  assert.equal(h.root.classList.contains('is-flying'), false);
  assert.equal(h.rafs.size, 1);
  assert.equal(h.timers.size, 0);
  h.advance(10000);
  visible(h.root, false);
  flying(h.dove, false);
  h.paint();
  visible(h.root);
  assert.equal(h.timers.size, 1);
  h.advance(1299);
  flying(h.dove, false);
  h.advance(1);
  flying(h.dove, false);
  h.advance(5499);
  flying(h.dove, false);
  assert.equal(h.root.classList.contains('is-flying'), false);
  h.advance(1);
  flying(h.dove);
  assert.equal(h.root.classList.contains('is-flying'), true);
  visible(h.root);
  h.animation();
  assert.equal(h.dove.isConnected, false);
  disposed(h);
  untouched(h);
});

for (const type of ['animationend', 'animationcancel']) {
  test(`${type} for the active dove immediately disposes the whole sequence and cancels the fallback without a frame fade`, () => {
    const h = setup();
    startFlight(h);
    const fallback = [...h.timers.values()][0].callback;
    h.advance(123);
    h.animation(type);
    disposed(h);
    assert.equal(h.dove.isConnected, false);
    assert.equal(h.frame.isConnected, false);
    const effects = h.effects.length;
    fallback();
    h.animation('animationend');
    h.animation('animationcancel');
    assert.equal(h.effects.length, effects, 'repeated or already-queued flight completion cannot schedule a fade or dispose twice');
    h.advance(10000);
    idle(h);
    untouched(h);
  });
}

test('missing animation events use the exact 1200ms flight fallback to dispose the whole sequence immediately', () => {
  const h = setup();
  startFlight(h);
  h.advance(1199);
  assert.equal(h.dove.isConnected, true);
  flying(h.dove);
  visible(h.root);
  h.advance(1);
  assert.equal(h.dove.isConnected, false);
  disposed(h);
  untouched(h);
});

test('unrelated animations, descendant targets, early flight events, and other keys do not shorten the sequence', () => {
  const h = setup();
  h.animation();
  h.animation('animationcancel');
  h.key('Enter');
  h.paint();
  h.advance(6799);
  h.animation();
  flying(h.dove, false);
  visible(h.root);
  h.advance(1);
  for (const type of ['animationend', 'animationcancel']) {
    h.animation(type, h.dove, 'another-animation');
    h.animation(type, h.path);
    h.animation(type, h.frame);
    h.animation(type, h.outside);
  }
  h.key('Tab');
  h.advance(1199);
  assert.equal(h.dove.isConnected, true);
  visible(h.root);
  h.animation();
  disposed(h);
});

test('a disabled/missing dove still displays the frame for fade-in + 5.5 seconds and fades out for 200ms', () => {
  const h = setup({ dove: false });
  h.paint();
  h.advance(6799);
  visible(h.root);
  assert.equal(h.frame.isConnected, true);
  h.advance(1);
  finishFade(h);
  untouched(h);
});

for (const dove of [true, false]) {
  test(`reduced motion with dove=${dove} holds a static frame for exactly 5500ms and removes immediately without flight/fade`, () => {
    const h = setup({ reduced: true, dove });
    assert.equal(h.timers.size, 0);
    h.paint();
    visible(h.root);
    h.advance(5499);
    assert.equal(h.root.isConnected, true);
    assert.equal(h.root.classList.contains('is-flying'), false);
    if (h.dove) flying(h.dove, false);
    h.advance(1);
    assert.equal(h.root.isConnected, false);
    if (h.dove) flying(h.dove, false);
    idle(h);
    untouched(h);
  });
}

test('missing matchMedia uses normal timing and animation rather than throwing', () => {
  const h = setup({ matchMedia: false });
  h.paint();
  h.advance(6799);
  flying(h.dove, false);
  h.advance(1);
  flying(h.dove);
  h.advance(1200);
  disposed(h);
});

test('without a frame, the dove flies on the first rAF and removes the whole root immediately on completion', () => {
  const h = setup({ frame: false });
  flying(h.dove, false);
  assert.equal(h.timers.size, 0);
  h.paint();
  flying(h.dove);
  visible(h.root);
  h.animation();
  assert.equal(h.dove.isConnected, false);
  disposed(h);
  untouched(h);
});

test('a frameless dove still has the exact 1200ms animation fallback, with no frame fade', () => {
  const h = setup({ frame: false });
  h.paint();
  h.advance(1199);
  assert.equal(h.root.isConnected, true);
  h.advance(1);
  assert.equal(h.root.isConnected, false);
  idle(h);
});

for (const options of [{ frame: false, reduced: true }, { frame: false, dove: false }, { frame: false, dove: false, reduced: true }]) {
  test(`no frame removes on the first rAF without flight when reduced or dove-disabled: ${JSON.stringify(options)}`, () => {
    const h = setup(options);
    assert.equal(h.root.isConnected, true);
    h.paint();
    assert.equal(h.root.isConnected, false);
    if (h.dove) flying(h.dove, false);
    idle(h);
    untouched(h);
  });
}

for (const phase of ['before rAF', 'holding', 'flying']) {
  test(`Escape ${phase} skips/stops flight, cancels pending work, and begins only one frame fade`, () => {
    const h = setup();
    if (phase !== 'before rAF') h.paint();
    if (phase === 'holding') h.advance(1234);
    if (phase === 'flying') h.advance(6800);
    const previousTimers = [...h.timers.keys()];
    const stale = phase === 'flying' ? [...h.timers.values()].map((timer) => timer.callback) : [];
    const event = h.key();
    assert.equal(event.defaultPrevented, false);
    assert.equal(h.dove.parent, null);
    assert.equal(h.root.classList.contains('is-flying'), false, 'Escape cancels the delayed CSS frame fade');
    if (phase !== 'flying') flying(h.dove, false);
    assert.equal(h.rafs.size, 0);
    assert.equal(h.timers.size, 1);
    for (const id of previousTimers) assert.equal(h.timers.has(id), false);
    const fadeTimers = [...h.timers.keys()];
    const effects = h.effects.length;
    h.key();
    h.animation();
    h.animation('animationcancel');
    for (const callback of stale) callback();
    assert.equal(h.effects.length, effects, 'late flight completion cannot interrupt or restart manual finish');
    assert.deepEqual([...h.timers.keys()], fadeTimers);
    finishFade(h);
    untouched(h);
  });
}

test('Escape with reduced motion or without a frame dismisses immediately', () => {
  for (const options of [{ reduced: true }, { frame: false }]) {
    const h = setup(options);
    h.paint();
    h.key();
    assert.equal(h.root.isConnected, false);
    assert.equal(h.dove.parent, null);
    if (options.reduced) flying(h.dove, false);
    idle(h);
    untouched(h);
  }
});

test('claims the legacy sessionStorage key once and deduplicates repeats without truncating the active sequence', () => {
  const h = setup();
  assert.deepEqual(h.storageCalls, [['get', storageKey('completion-1')], ['set', storageKey('completion-1'), 'shown']]);
  h.paint();
  h.advance(4000);
  const holdTimer = [...h.timers.keys()];
  const duplicate = h.makeCompletion();
  h.flushMutations();
  assert.equal(duplicate.root.isConnected, false);
  assert.equal(h.root.isConnected, true);
  visible(h.root);
  assert.deepEqual([...h.timers.keys()], holdTimer);
  assert.equal(h.storageCalls.length, 2, 'in-memory deduplication avoids another storage access');
  h.advance(2799);
  flying(h.dove, false);
  h.advance(1);
  flying(h.dove);
  h.animation();
  disposed(h);
  const replay = h.makeCompletion();
  h.flushMutations();
  assert.equal(replay.root.isConnected, false);
  idle(h);
});

test('a previously shown event from sessionStorage never unhides, schedules, or supersedes another event', () => {
  const storage = new Map([[storageKey('old-event'), 'shown']]);
  const cached = setup({ storage, eventId: 'old-event' });
  assert.equal(cached.root.isConnected, false);
  assert.equal(cached.root.hidden, true);
  assert.equal(cached.root.layoutReads, 0);
  idle(cached);
  const h = setup({ storage });
  h.paint();
  h.advance(5500);
  const old = h.makeCompletion('old-event');
  h.flushMutations();
  assert.equal(old.root.isConnected, false);
  assert.equal(h.root.isConnected, true);
  h.advance(1300);
  flying(h.dove);
  h.animation();
  disposed(h);
});

test('the storage key prevents replay across separate script contexts, but non-shown values do not', () => {
  const storage = new Map([[storageKey('completion-1'), 'not-shown']]);
  const first = setup({ storage });
  assert.equal(first.root.isConnected, true);
  first.context.Bible270CompletionUI.cleanup();
  const second = setup({ storage });
  assert.equal(second.root.isConnected, false);
  idle(second);
});

for (const storageThrows of ['access', 'get', 'set']) {
  test(`sessionStorage ${storageThrows} throwing uses in-memory deduplication and still permits new events`, () => {
    const h = setup({ storageThrows });
    startFlight(h);
    const duplicate = h.makeCompletion();
    h.flushMutations();
    assert.equal(duplicate.root.isConnected, false);
    assert.equal(h.root.isConnected, true);
    flying(h.dove);
    h.animation();
    disposed(h);
    const replay = h.makeCompletion();
    h.flushMutations();
    assert.equal(replay.root.isConnected, false);
    const next = h.makeCompletion('next-event');
    h.flushMutations();
    assert.equal(next.root.isConnected, true);
    assert.equal(next.root.hidden, false);
    h.paint();
    h.advance(6800);
    flying(next.dove);
    h.animation('animationend', next.dove);
    disposed(h, next.root);
    untouched(h, next);
  });
}

test('missing and empty event IDs remove unclaimed roots without disturbing the current completion', () => {
  const h = setup();
  h.paint();
  h.advance(5500);
  for (const id of [null, '']) {
    const invalid = h.makeCompletion(id);
    h.flushMutations();
    assert.equal(invalid.root.isConnected, false);
    assert.equal(invalid.root.hidden, true);
  }
  assert.equal(h.storageCalls.length, 2);
  assert.equal(h.root.isConnected, true);
  h.advance(1300);
  flying(h.dove);
  h.animation();
  disposed(h);
});

test('the observer initializes inserted roots and nested containers, ignores text nodes, and survives reparenting', () => {
  const h = setup();
  h.context.Bible270CompletionUI.cleanup();
  h.flushMutations();
  assert.equal(h.observers.length, 1);
  assert.equal(h.observers[0].target, h.document.documentElement);
  assert.equal(h.observers[0].options.childList, true);
  assert.equal(h.observers[0].options.subtree, true);
  h.observers[0].callback([{ addedNodes: [{ nodeType: 3, textContent: 'not an element' }] }]);
  const direct = h.makeCompletion('direct');
  h.flushMutations();
  assert.equal(direct.root.parent, h.document.body);
  assert.equal(direct.root.layoutReads, 1);
  assert.equal(h.rafs.size, 1);
  const wrapper = h.element('section');
  const nested = h.makeCompletion('nested', { parent: wrapper });
  h.container.appendChild(wrapper);
  h.flushMutations();
  assert.equal(direct.root.isConnected, false);
  assert.equal(nested.root.parent, h.document.body);
  assert.equal(wrapper.children.length, 0);
  assert.equal(nested.root.layoutReads, 1);
  assert.equal(h.rafs.size, 1);
  h.paint();
  h.advance(6800);
  flying(nested.dove);
  h.animation('animationend', nested.dove);
  disposed(h, nested.root);
});

for (const phase of ['before rAF', 'holding', 'flying', 'fading']) {
  test(`repeat script evaluation, resets, Turbo load and pageshow ${phase} install only one observer/listener set and preserve timing`, () => {
    const h = setup();
    const singleton = h.context.Bible270CompletionUI;
    if (phase !== 'before rAF') h.paint();
    if (phase === 'holding') h.advance(1234);
    if (phase === 'flying' || phase === 'fading') h.advance(6800);
    if (phase === 'fading') beginManualFade(h);
    const timerIds = [...h.timers.keys()];
    const rafIds = [...h.rafs.keys()];
    const effectCount = h.effects.length;
    h.evaluate();
    h.evaluate();
    singleton.reset();
    singleton.reset(h.root);
    singleton.reset(h.container);
    h.emit('turbo:load');
    h.emit('pageshow', h.context, {}, true);
    h.flushMutations();
    assert.equal(h.context.Bible270CompletionUI, singleton);
    assert.equal(h.observers.length, 1);
    assert.deepEqual([...h.documentListeners.keys()].sort(), ['animationcancel', 'animationend', 'keydown', 'turbo:before-cache', 'turbo:before-render', 'turbo:load']);
    assert.deepEqual([...h.windowListeners.keys()].sort(), ['pagehide', 'pageshow']);
    for (const listeners of [...h.documentListeners.values(), ...h.windowListeners.values()]) assert.equal(listeners.length, 1);
    assert.equal(h.effects.length, effectCount);
    assert.deepEqual([...h.timers.keys()], timerIds);
    assert.deepEqual([...h.rafs.keys()], rafIds);
    assert.equal(h.storageCalls.length, 2);
    if (phase === 'before rAF') h.paint();
    if (phase === 'before rAF') h.advance(6800);
    if (phase === 'holding') { h.advance(5565); flying(h.dove, false); h.advance(1); }
    if (phase === 'fading') finishFade(h);
    else { flying(h.dove); h.animation(); disposed(h); }
  });
}

for (const phase of ['before rAF', 'holding', 'flying', 'fading']) {
  test(`a different event supersedes the old sequence ${phase}, and old callbacks/animations cannot affect the new event`, () => {
    const h = setup();
    if (phase !== 'before rAF') h.paint();
    if (phase === 'holding') h.advance(2000);
    if (phase === 'flying' || phase === 'fading') h.advance(6800);
    if (phase === 'fading') beginManualFade(h);
    const stale = [...h.rafs.values(), ...[...h.timers.values()].map((timer) => timer.callback)];
    const next = h.makeCompletion('new-event');
    h.flushMutations();
    assert.equal(h.root.isConnected, false);
    assert.equal(next.root.parent, h.document.body);
    visible(next.root, false);
    assert.equal(h.timers.size, 0);
    assert.equal(h.rafs.size, 1);
    const effectCount = h.effects.length;
    for (const callback of stale) callback();
    h.animation();
    assert.equal(h.effects.length, effectCount);
    h.paint();
    h.advance(6799);
    flying(next.dove, false);
    h.advance(1);
    flying(next.dove);
    h.animation();
    h.animation('animationcancel', h.dove);
    assert.equal(next.dove.isConnected, true, 'old dove events cannot finish the new flight');
    h.animation('animationend', next.dove);
    disposed(h, next.root);
    untouched(h, next);
  });
}

for (const event of ['pagehide', 'turbo:before-cache', 'turbo:before-render']) {
  for (const phase of ['before rAF', 'holding', 'flying', 'fading']) {
    test(`${event} ${phase} cancels all scheduled work, removes all roots, and makes late callbacks harmless`, () => {
      const h = setup();
      if (phase !== 'before rAF') h.paint();
      if (phase === 'holding') h.advance(1000);
      if (phase === 'flying' || phase === 'fading') h.advance(6800);
      if (phase === 'fading') beginManualFade(h);
      const stale = [...h.rafs.values(), ...[...h.timers.values()].map((timer) => timer.callback)];
      h.emit(event, event === 'pagehide' ? h.context : h.document, {}, event === 'pagehide');
      assert.equal(h.root.isConnected, false);
      assert.equal(h.document.querySelectorAll('[data-b270-completion]').length, 0);
      idle(h);
      const effectCount = h.effects.length;
      h.flushMutations();
      for (const callback of stale) callback();
      h.animation();
      h.animation('animationcancel');
      h.key();
      h.emit(event, h.document, {}, event === 'pagehide');
      h.paint();
      h.advance(20000);
      assert.equal(h.effects.length, effectCount);
      idle(h);
      untouched(h);
    });
  }
}

for (const event of ['pagehide', 'turbo:before-cache', 'turbo:before-render']) {
  test(`${event} cannot resurrect an uninitialized root from a queued mutation delivery`, () => {
    const h = setup();
    h.paint();
    const pending = h.makeCompletion('not-yet-observed');
    assert.equal(pending.root.dataset.b270CompletionInitialized, undefined);
    h.emit(event, event === 'pagehide' ? h.context : h.document, {}, event === 'pagehide');
    assert.equal(h.root.isConnected, false);
    assert.equal(pending.root.isConnected, false);
    idle(h);
    h.flushMutations();
    assert.equal(pending.root.isConnected, false, 'a delayed observer record must not reattach a root removed by navigation cleanup');
    assert.equal(h.document.querySelectorAll('[data-b270-completion]').length, 0);
    assert.equal(h.storage.has(storageKey('not-yet-observed')), false, 'discarded completions must not be claimed by a stale observer');
    idle(h);
  });
}

test('cleanup is repeatable and a restored cached event cannot replay, while a fresh event can initialize', () => {
  const h = setup();
  h.paint();
  h.context.Bible270CompletionUI.cleanup();
  h.flushMutations();
  h.context.Bible270CompletionUI.cleanup();
  h.emit('pageshow', h.context, {}, true);
  h.emit('turbo:load');
  idle(h);
  const replay = h.makeCompletion();
  h.flushMutations();
  assert.equal(replay.root.isConnected, false);
  const next = h.makeCompletion('after-navigation');
  h.flushMutations();
  h.paint();
  h.advance(6800);
  flying(next.dove);
  h.animation('animationend', next.dove);
  disposed(h, next.root);
});

for (const phase of ['before rAF', 'holding', 'flying', 'fading']) {
  test(`disconnecting a long root ${phase} is safe and late work never reattaches it or starts flight`, () => {
    const h = setup({ long: true });
    assert.equal(h.root.rect.height, 24000);
    if (phase !== 'before rAF') h.paint();
    if (phase === 'holding') h.advance(2000);
    if (phase === 'flying' || phase === 'fading') h.advance(6800);
    if (phase === 'fading') beginManualFade(h);
    h.root.remove();
    const effectCount = h.effects.length;
    h.paint();
    h.advance(20000);
    h.animation();
    h.key();
    assert.equal(h.effects.length, effectCount);
    assert.equal(h.root.isConnected, false);
    idle(h);
    if (phase === 'before rAF' || phase === 'holding') flying(h.dove, false);
    untouched(h);
    const next = h.makeCompletion('after-disconnect');
    h.flushMutations();
    h.paint();
    h.advance(6800);
    flying(next.dove);
    h.animation('animationend', next.dove);
    disposed(h, next.root);
    untouched(h, next);
  });
}

test('completion layout centers, scrolls, preserves theme surfaces and dove stacking, and fades both together without a final freeze (optional Chromium)', { timeout: 60000 }, (t) => {
  const { spawnSync } = require('node:child_process');
  const browser = process.env.CHROME_BIN || 'chromium';
  const probe = spawnSync(browser, ['--version'], { timeout: 15000, encoding: 'utf8' });
  if (!process.env.CHROME_BIN && probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; full-script VM tests still run');
  assert.ifError(probe.error);
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const stripERB = (name) => readFileSync(resolve(__dirname, `../../app/views/bible270/shared/${name}.html.erb`), 'utf8').replace(/<%[\s\S]*?%>/g, '');
  const styles = stripERB('_styles');
  const figure = stripERB('_scripture_frame');
  const doveMarkup = stripERB('_day_completion_dove');
  const browserCheck = function(styles, figure, doveMarkup) {
    const failures = [];
    const surfaces = new Set();
    const check = (condition, message) => { if (!condition) failures.push(message); };
    const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    for (const [width, height] of [[360, 720], [844, 390], [1280, 720]]) {
      const viewport = document.createElement('iframe');
      viewport.style.cssText = `display:block;border:0;width:${width}px;height:${height}px`;
      document.body.append(viewport);
      const doc = viewport.contentDocument;
      doc.open();
      doc.write(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">${styles}</head>
        <body class="b270" data-display-mode="light">
        <div class="b270-completion" data-b270-completion data-b270-completion-event="layout" hidden>
          <div class="b270-completion-frame" data-b270-completion-frame>${figure}</div>
          ${doveMarkup}
        </div></body></html>`);
      doc.close();
      const css = (node) => viewport.contentWindow.getComputedStyle(node);
      const root = doc.querySelector('[data-b270-completion]');
      const frame = doc.querySelector('[data-b270-completion-frame]');
      const dove = doc.querySelector('[data-b270-completion-dove]');
      const text = doc.querySelector('[data-b270-scripture-text]');
      const centeredAndBounded = (label) => {
        const rect = frame.getBoundingClientRect();
        check(rect.width > 0 && rect.height > 0, `${width}/${label}: frame is laid out`);
        check(Math.abs((rect.left + rect.right) / 2 - width / 2) < 1 && Math.abs((rect.top + rect.bottom) / 2 - height / 2) < 1, `${width}/${label}: frame centered`);
        check(rect.left >= 11.5 && rect.right <= width - 11.5 && rect.top >= 11.5 && rect.bottom <= height - 11.5, `${width}/${label}: frame stays within viewport gutters`);
        check(doc.documentElement.scrollWidth <= width && frame.scrollWidth <= frame.clientWidth + 1, `${width}/${label}: no horizontal overflow`);
      };
      check(css(root).display === 'none' && frame.getClientRects().length === 0, `${width}: hidden root is display:none`);
      root.hidden = false;
      text.textContent = 'The LORD is my shepherd,\nI shall not want.';
      doc.querySelector('[data-b270-scripture-reference]').textContent = 'Psalm 23:1';
      doc.querySelector('[data-b270-scripture-translation]').textContent = 'NASB95';
      check(css(frame).opacity === '0', `${width}: frame starts transparent`);
      check(reduced || (css(frame).transitionProperty === 'opacity' && css(frame).transitionDuration === '0.2s'), `${width}: normal fade-out is 0.2 seconds`);
      frame.getBoundingClientRect();
      root.classList.add('is-visible');
      check(reduced || css(frame).transitionDuration === '1.3s', `${width}: fade-in lasts 1.3 seconds`);
      frame.getAnimations().forEach((animation) => animation.finish());
      check(css(frame).opacity === '1', `${width}: visible frame fades to opaque`);
      check(css(root).pointerEvents === 'none' && css(frame).pointerEvents === 'auto', `${width}: only the visible frame receives pointer events`);
      centeredAndBounded('short');
      const swatch = doc.createElement('span');
      doc.body.append(swatch);
      const background = (node) => {
        // Reduced-motion CSS gives even palette changes a tiny transition; settle it before comparing.
        node.getAnimations().forEach((animation) => animation.finish());
        return css(node).backgroundColor;
      };
      for (const theme of ['light', 'sage', 'mist', 'dark', 'dark_green', 'dark_blue']) {
        doc.body.dataset.displayMode = theme;
        swatch.style.backgroundColor = theme === 'sage' ? '#d1e2ea' : 'color-mix(in srgb,var(--card) 90%,var(--gold))';
        const surface = background(doc.querySelector('.b270-scripture-art__mat'));
        check(surface === background(swatch), `${width}/${theme}: mat retains its theme-specific surface`);
        swatch.style.backgroundColor = 'var(--card)';
        check(surface !== background(swatch), `${width}/${theme}: mat differs from the plain card surface`);
        surfaces.add(surface);
      }
      swatch.remove();
      dove.classList.add('b270-completion-dove-active');
      root.classList.add('is-flying');
      check(css(root).position === 'fixed' && css(dove).position === 'absolute' && css(dove).pointerEvents === 'none', `${width}: dove is anchored inside the fixed overlay and noninteractive`);
      const artwork = dove.querySelector(':scope > svg');
      check(dove.tagName === 'DIV' && artwork?.viewBox.baseVal.width === 260, `${width}: the actual dove SVG lives inside an HTML animation layer`);
      check(css(dove).filter === 'none' && css(artwork).filter === 'none' && css(dove).willChange === 'auto', `${width}: SVG scaling avoids filtered or pre-rasterized layers`);
      if (reduced) {
        check(css(dove).display === 'none', `${width}: reduced motion hides the dove`);
        check(parseFloat(css(frame).transitionDuration) < 0.001, `${width}: reduced motion removes the perceptible fade`);
      } else {
        const animation = dove.getAnimations().find((animation) => animation.animationName === 'b270-dove-flight');
        const frameAnimation = root.getAnimations().find((animation) => animation.animationName === 'b270-completion-exit');
        check(!!animation, `${width}: dove flight animation exists`);
        check(!!frameAnimation, `${width}: shared end-of-flight fade exists`);
        const at = (time) => {
          for (const flight of [animation, frameAnimation].filter(Boolean)) {
            flight.pause();
            flight.currentTime = time;
          }
          const opacity = Number(css(root).opacity);
          const transform = new viewport.contentWindow.DOMMatrix(css(dove).transform);
          return { frame: Number(css(frame).opacity) * opacity, dove: Number(css(dove).opacity) * opacity,
            top: dove.getBoundingClientRect().top + dove.getBoundingClientRect().height / 2, scale: Math.hypot(transform.a, transform.b) };
        };
        if (animation && frameAnimation) {
          const doveTiming = animation.effect.getComputedTiming();
          const frameTiming = frameAnimation.effect.getComputedTiming();
          check(doveTiming.duration === 1000, `${width}: dove flight lasts one second`);
          check(frameTiming.duration === 200 && Math.abs(frameTiming.delay - 800) < 0.01 && css(root).animationTimingFunction === 'ease-in-out', `${width}: shared fade covers the flight's final 200ms`);
          check(Math.abs(frameTiming.endTime - doveTiming.endTime) < 0.01 && frameTiming.fill === 'both', `${width}: frame exit ends with the dove`);
        }
        at(650);
        check(Number(css(dove).opacity) > 0 && css(dove).visibility === 'visible' && css(dove).display !== 'none', `${width}: mid-flight dove is visible`);
        check(Number(css(dove).zIndex) > (Number(css(frame).zIndex) || 0), `${width}: dove stacks above the frame`);
        // Temporarily enable hit testing to verify paint order, not just z-index declarations.
        dove.style.pointerEvents = 'auto';
        check(dove.contains(doc.elementFromPoint(width / 2, height / 2)), `${width}: the dove paints above the frame at their overlap`);
        dove.style.removeProperty('pointer-events');
        let previous = at(350);
        for (const time of [450, 600, 700, 800, 850, 900, 950, 990, 999]) {
          const sample = at(time);
          if (time <= 800) check(sample.frame === 1 && sample.dove > 0.7, `${width}/${time}ms: frame stays opaque until the final 200ms`);
          else {
            check(sample.frame > 0 && sample.frame < previous.frame, `${width}/${time}ms: frame visibly fades before flight ends`);
            check(sample.dove > 0 && sample.dove < previous.dove && Math.abs(sample.dove - sample.frame) < 0.05, `${width}/${time}ms: dove and frame fade together`);
          }
          check(sample.top < previous.top && sample.scale > previous.scale, `${width}/${time}ms: dove keeps moving and growing without a final freeze`);
          previous = sample;
        }
        const overlay = root.getBoundingClientRect();
        const coveredByBird = () => {
          const inverse = artwork.getScreenCTM().inverse();
          const paths = [...artwork.querySelectorAll('.b270-dove-silhouette path')];
          return [0, .25, .5, .75, 1].every((x) => [0, .25, .5, .75, 1].every((y) => {
            const point = new viewport.contentWindow.DOMPoint(overlay.left + x * overlay.width, overlay.top + y * overlay.height).matrixTransform(inverse);
            return paths.some((path) => path.isPointInFill(point));
          }));
        };
        at(550);
        const earlyBounds = dove.getBoundingClientRect();
        check(earlyBounds.width < overlay.width && earlyBounds.height < overlay.height, `${width}: the dove remains recognizable throughout the flight`);
        at(800);
        check(!coveredByBird(), `${width}: the dove does not create a screen-filling white flash before fading`);
        check(css(root).overflow === 'hidden', `${width}: the zoom is clipped to the viewport`);
        const flightEnd = at(1000);
        check(!coveredByBird(), `${width}: the finish preserves the dove silhouette instead of flashing white`);
        check(Math.abs(flightEnd.scale - 1.15) < 0.001, `${width}: dove continues growing through the final fade`);
        check(flightEnd.frame === 0 && flightEnd.dove === 0 && css(root).visibility === 'hidden', `${width}: frame and dove finish fading together at one second`);
        if (animation && frameAnimation) {
          // Changing the shared duration must move both endpoints, not leave a fixed frame delay behind.
          root.style.setProperty('--b270-dove-duration', '2.1s');
          root.getAnimations(); // Flush the updated CSS timing before inspecting the existing animation objects.
          const doveTiming = animation.effect.getComputedTiming();
          const frameTiming = frameAnimation.effect.getComputedTiming();
          check(doveTiming.duration === 2100 && frameTiming.duration === 200 && Math.abs(frameTiming.delay - 1900) < 0.01 && Math.abs(frameTiming.endTime - doveTiming.endTime) < 0.01,
            `${width}: shared fade and dove duration share --b270-dove-duration`);
          root.style.removeProperty('--b270-dove-duration');
        }
      }
      root.classList.remove('is-flying');
      check(css(frame).opacity === '1', `${width}: canceling the flight animation restores the visible frame before manual fade`);
      text.textContent = 'A long completion verse with preserved newlines.\n'.repeat(200) + 'unbroken'.repeat(100);
      centeredAndBounded('long');
      check(css(frame).overflowY === 'auto' && frame.scrollHeight > frame.clientHeight, `${width}: long text has a bounded scroll area`);
      frame.scrollTop = 50;
      check(frame.scrollTop === 50, `${width}: long text actually scrolls`);
      root.classList.remove('is-visible');
      check(reduced || css(frame).transitionDuration === '0.2s', `${width}: fade-out lasts 0.2 seconds`);
      frame.getAnimations().forEach((animation) => animation.finish());
      check(css(frame).opacity === '0', `${width}: frame fades out again`);
      viewport.remove();
    }
    check(surfaces.size === 6, 'all six themes retain distinct mat backgrounds');
    const result = document.createElement('pre');
    result.id = 'result';
    result.textContent = JSON.stringify({ failures, reduced });
    document.body.append(result);
  };
  const page = `<!doctype html><html><body><script>try {
    (${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(figure)},${JSON.stringify(doveMarkup)});
  } catch (error) {
    const result = document.createElement('pre');
    result.id = 'result';
    result.textContent = JSON.stringify({ error: error.stack || String(error) });
    document.body.append(result);
  }</script></body></html>`;
  for (const reduced of [false, true]) {
    const result = spawnSync(browser, ['--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-background-networking',
      ...(reduced ? ['--force-prefers-reduced-motion'] : []), '--dump-dom', '--timeout=6000', '--virtual-time-budget=1000', `data:text/html,${encodeURIComponent(page)}`], {
      timeout: 20000, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr || String(result.error));
    const output = result.stdout.match(/<pre id="result">([^<]*)<\/pre>/);
    assert.ok(output, `${browser} completed completion layout checks: ${result.stderr}\n${result.stdout.slice(0, 1000)}`);
    const report = JSON.parse(output[1].replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
    assert.equal(report.error, undefined, report.error);
    assert.equal(report.reduced, reduced, 'Chromium applied the requested motion preference');
    assert.deepEqual(report.failures, [], JSON.stringify(report.failures, null, 2));
  }
});
