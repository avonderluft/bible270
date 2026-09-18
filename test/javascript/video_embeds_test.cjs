const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_video_embeds.html.erb');
// Remove ERB before the script wrapper: the nonce expression itself contains a `>`.
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];

const validId = 'Abc_123-xyZ'; // Eleven characters, including both allowed punctuation marks.

// Only the selectors and tree operations used by the video controller are needed.
class Element {
  constructor(tag, dataset = {}) {
    this.tag = tag;
    this.dataset = dataset;
    this.children = [];
    this.parent = null;
    this.hidden = false;
  }

  matches(selector) {
    if (selector === '.b270-video') return this.className === 'b270-video';
    if (selector === '[data-b270-video-load]') return 'b270VideoLoad' in this.dataset;
    if (selector === '[data-b270-video-id]') return 'b270VideoId' in this.dataset;
    if (selector === 'iframe') return this.tag === 'iframe';
    if (selector === '.b270-video iframe') return this.tag === 'iframe' && !!this.parent?.closest('.b270-video');
    throw new Error(`Unsupported selector: ${selector}`);
  }

  closest(selector) {
    return this.matches(selector) ? this : this.parent?.closest(selector) || null;
  }

  querySelectorAll(selector) {
    return this.children.flatMap((child) => [
      ...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)
    ]);
  }

  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  append(child) { child.parent = this; this.children.push(child); return child; }
  insertBefore(child, before) {
    assert.equal(before.parent, this);
    child.parent = this;
    this.children.splice(this.children.indexOf(before), 0, child);
  }
  remove() {
    this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
  focus() { this.focused = true; }
}

function harness() {
  const document = new Element('document');
  document.documentElement = document.append(new Element('html'));
  const listeners = new Map();
  const observers = [];
  const created = [];
  const requests = [];
  const network = (...args) => {
    requests.push(args);
    assert.fail('Unexpected network API call');
  };
  document.addEventListener = (type, callback) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push(callback);
  };
  document.createElement = (tag) => {
    const element = new Element(tag);
    created.push(element);
    // Model resource assignments; no real browser/network is involved in these tests.
    Object.defineProperty(element, 'src', {
      get() { return this.source; },
      set(value) { this.source = value; requests.push(value); }
    });
    return element;
  };
  class MutationObserver {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(root, options) { this.root = root; this.options = options; }
  }
  const context = vm.createContext({ document, MutationObserver, fetch: network,
    XMLHttpRequest: function () { network(); }, Image: function () { network(); } });
  context.window = context;
  const emit = (type, target = document) => {
    for (const callback of listeners.get(type) || []) callback({ type, target });
  };
  return {
    document, context, listeners, observers, created, requests,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit,
    click: (target) => emit('click', target),
    // Explicit delivery models the observer microtask without implementing a browser event loop.
    mutate: () => observers.forEach((observer) => observer.callback([], observer)),
    card(id = validId, root = document.documentElement) {
      const card = root.append(new Element('div', { b270VideoId: id }));
      card.className = 'b270-video';
      const button = card.append(new Element('button', { b270VideoLoad: '' }));
      button.hidden = true; // The server-rendered fallback starts hidden without JS.
      return { card, button };
    }
  };
}

function frames(card) { return card.querySelectorAll('iframe'); }

test('initial scan reveals controls without creating an iframe or requesting resources', () => {
  const h = harness();
  const { card, button } = h.card();
  h.evaluate();
  assert.equal(button.hidden, false);
  assert.deepEqual(frames(card), []);
  assert.deepEqual(h.created, []);
  assert.deepEqual(h.requests, []);
  assert.equal(h.observers.length, 1);
  assert.equal(h.observers[0].root, h.document.documentElement);
  assert.equal(h.observers[0].options.childList, true);
  assert.equal(h.observers[0].options.subtree, true);
});

test('delegated click creates one fixed privacy-enhanced iframe without autoplay', () => {
  const h = harness();
  const { card, button } = h.card();
  const label = button.append(new Element('span'));
  h.evaluate();
  h.click(label);
  const [frame] = frames(card);
  assert.ok(frame);
  assert.equal(frame.src, `https://www.youtube-nocookie.com/embed/${validId}?autoplay=0`);
  assert.equal(frame.title, 'YouTube video player');
  assert.equal(frame.referrerPolicy, 'strict-origin-when-cross-origin');
  assert.equal(frame.allow, 'encrypted-media; fullscreen; picture-in-picture');
  assert.equal(frame.allowFullscreen, true);
  assert.equal(frame.focused, true);
  assert.equal(button.hidden, true);
  assert.deepEqual(card.children, [frame, button]);
  assert.deepEqual(h.requests, [frame.src]);
});

test('repeated clicks, scans, and script evaluation preserve the single loaded iframe', () => {
  const h = harness();
  const { card, button } = h.card();
  h.evaluate();
  const controller = h.context.Bible270Videos;
  h.click(button);
  const [frame] = frames(card);
  h.click(button);
  h.mutate();
  assert.equal(button.hidden, true, 'mutation scans must not reveal a loaded control');
  h.emit('turbo:load');
  h.evaluate();
  h.click(button);
  assert.equal(h.context.Bible270Videos, controller);
  assert.deepEqual(frames(card), [frame]);
  assert.equal(button.hidden, true);
  assert.equal(h.created.length, 1);
  assert.equal(h.requests.length, 1);
  assert.equal(h.observers.length, 1);
  for (const type of ['click', 'turbo:load', 'turbo:before-cache']) {
    assert.equal(h.listeners.get(type).length, 1, `${type} is registered once`);
  }
});

test('mutation scans discover newly inserted cards without loading them', () => {
  const h = harness();
  h.evaluate();
  const { card, button } = h.card();
  h.mutate();
  assert.equal(button.hidden, false);
  assert.deepEqual(h.created, []);
  assert.deepEqual(h.requests, []);
  h.click(button);
  assert.equal(frames(card).length, 1);
});

test('scoped reset removes only its frames, restores controls, and permits reload', () => {
  const h = harness();
  const preview = h.document.documentElement.append(new Element('section'));
  const inside = h.card(validId, preview);
  const outside = h.card();
  h.evaluate();
  h.click(inside.button);
  h.click(outside.button);
  const [oldFrame] = frames(inside.card);
  h.context.Bible270Videos.reset(preview);
  assert.deepEqual(frames(inside.card), []);
  assert.equal(inside.button.hidden, false);
  assert.equal(frames(outside.card).length, 1);
  assert.equal(outside.button.hidden, true);
  h.click(inside.button);
  assert.equal(frames(inside.card).length, 1);
  assert.notEqual(frames(inside.card)[0], oldFrame);
});

for (const reset of ['reset', 'turbo:before-cache']) {
  test(`${reset} removes all frames and restores controls, including on repeated cleanup`, () => {
    const h = harness();
    const cards = [h.card(), h.card(), h.card()];
    h.evaluate();
    cards.slice(0, 2).forEach(({ button }) => h.click(button));
    for (let i = 0; i < 2; i++) {
      if (reset === 'reset') h.context.Bible270Videos.reset();
      else h.emit(reset);
      h.mutate();
      for (const { card, button } of cards) {
        assert.deepEqual(frames(card), []);
        assert.equal(button.hidden, false);
      }
    }
    assert.equal(h.requests.length, 2, 'cleanup must not request more resources');
  });
}

test('invalid or missing IDs and unrelated clicks never create frames or requests', () => {
  const h = harness();
  const ids = [undefined, '', 'short', `${validId}x`, 'abcdefghij!', '../abcdefgh',
    ` ${validId}`, `${validId}\n`, 'https://youtu.be/Abc_123-xyZ'];
  const cards = ids.map((id) => {
    const card = h.card();
    if (id === undefined) delete card.card.dataset.b270VideoId;
    else card.card.dataset.b270VideoId = id;
    return card;
  });
  h.evaluate();
  h.click(h.document.documentElement);
  h.click({}); // Targets without closest are safely ignored.
  cards.forEach(({ button }) => h.click(button));
  assert.deepEqual(h.created, []);
  assert.deepEqual(h.requests, []);
  cards.forEach(({ button }) => assert.equal(button.hidden, false));
});
