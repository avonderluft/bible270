const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_header.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];

class Element {
  constructor(tag, className = '') {
    this.tag = tag;
    this.className = className;
    this.children = [];
    this.parent = null;
    this.attributes = {};
    this.hidden = false;
    this.focusCalls = 0;
  }
  matches(selector) {
    if (selector === '.b270-navmenu') return this.className === 'b270-navmenu';
    if (selector === '.b270-navlinks') return this.className === 'b270-navlinks';
    if (selector === 'button.b270-navtoggle') return this.tag === 'button' && this.className === 'b270-navtoggle';
    throw new Error(`Unsupported selector: ${selector}`);
  }
  closest(selector) { return this.matches(selector) ? this : this.parent?.closest(selector) || null; }
  contains(target) { return this === target || this.children.some((child) => child.contains(target)); }
  querySelectorAll(selector) {
    return this.children.flatMap((child) => [
      ...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)
    ]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  append(child) { child.parent = this; this.children.push(child); return child; }
  remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  focus() {
    this.focusCalls++;
    let root = this;
    while (root.parent) root = root.parent;
    root.activeElement = this;
  }
}

function harness() {
  const document = new Element('document');
  const listeners = new Map();
  document.addEventListener = (type, callback) => {
    if (!listeners.has(type)) listeners.set(type, []);
    listeners.get(type).push(callback);
  };
  const context = vm.createContext({ document, window: {} });
  const emit = (type, target, properties = {}) => {
    const event = { type, target, defaultPrevented: false, propagationStopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.propagationStopped = true; }, ...properties };
    for (const callback of listeners.get(type) || []) callback(event);
    return event;
  };
  return {
    document, listeners,
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    emit,
    click: (target) => emit('click', target),
    keydown: (target, key = 'Escape', properties = {}) => emit('keydown', target, { key, ...properties }),
    menu() {
      const menu = document.append(new Element('div', 'b270-navmenu'));
      const toggle = menu.append(new Element('button', 'b270-navtoggle'));
      toggle.setAttribute('aria-expanded', 'false');
      toggle.setAttribute('aria-controls', 'b270-mobile-navigation');
      const icon = toggle.append(new Element('svg')).append(new Element('path'));
      const links = menu.append(new Element('div', 'b270-navlinks'));
      links.hidden = true;
      const link = links.append(new Element('a'));
      return { menu, toggle, icon, links, link };
    }
  };
}

function assertExpanded(menu, expanded) {
  assert.equal(menu.toggle.getAttribute('aria-expanded'), String(expanded));
  assert.equal(menu.links.hidden, !expanded);
}

test('nested toggle clicks keep hidden and aria-expanded synchronized in both directions', () => {
  const h = harness();
  const menu = h.menu();
  h.evaluate();
  assertExpanded(menu, false);
  assert.equal(h.click(menu.icon).defaultPrevented, false);
  assertExpanded(menu, true);
  h.click(menu.toggle);
  assertExpanded(menu, false);
});

test('inside clicks preserve navigation, outside clicks close without moving or stealing focus', () => {
  const h = harness();
  const menu = h.menu();
  const outside = h.document.append(new Element('textarea'));
  h.evaluate();
  h.click(menu.toggle);
  menu.link.focus();
  const linkClick = h.click(menu.link);
  assertExpanded(menu, true);
  assert.equal(linkClick.defaultPrevented, false);
  assert.equal(linkClick.propagationStopped, false);
  outside.focus(); // Model the browser focusing the clicked control before click delivery.
  const outsideClick = h.click(outside);
  assertExpanded(menu, false);
  assert.equal(h.document.activeElement, outside);
  assert.equal(menu.toggle.focusCalls, 0);
  assert.equal(outsideClick.defaultPrevented, false);
  assert.equal(outsideClick.propagationStopped, false);
  h.click(menu.toggle);
  menu.link.focus();
  h.click(h.document); // Non-focusable outside targets must not trigger focus restoration either.
  assertExpanded(menu, false);
  assert.equal(h.document.activeElement, menu.link);
  assert.equal(menu.toggle.focusCalls, 0);
});

for (const focused of ['toggle', 'link']) {
  test(`Escape from focused ${focused} closes the menu and focuses its toggle`, () => {
    const h = harness();
    const menu = h.menu();
    h.evaluate();
    h.click(menu.toggle);
    menu[focused].focus();
    let hidden = menu.links.hidden;
    Object.defineProperty(menu.links, 'hidden', {
      get() { return hidden; },
      set(value) {
        hidden = value;
        // A browser may clear focus when the focused link becomes hidden.
        if (value && menu.links.contains(h.document.activeElement)) h.document.activeElement = h.document;
      }
    });
    const calls = menu.toggle.focusCalls;
    const event = h.keydown(menu[focused]);
    assertExpanded(menu, false);
    assert.equal(h.document.activeElement, menu.toggle);
    assert.equal(menu.toggle.focusCalls, calls + 1);
    assert.equal(event.defaultPrevented, true);
    const closedEvent = h.keydown(menu.toggle);
    assert.equal(closedEvent.defaultPrevented, false);
    assert.equal(menu.toggle.focusCalls, calls + 1);
  });
}

test('Escape outside the menu, other keys, and already-handled Escape remain untouched', () => {
  const h = harness();
  const menu = h.menu();
  const editor = h.document.append(new Element('textarea'));
  h.evaluate();
  h.click(menu.toggle);
  editor.focus();
  const escape = h.keydown(editor);
  assertExpanded(menu, true);
  assert.equal(escape.defaultPrevented, false);
  assert.equal(escape.propagationStopped, false);
  assert.equal(h.document.activeElement, editor);
  assert.equal(menu.toggle.focusCalls, 0);
  menu.link.focus();
  const tab = h.keydown(menu.link, 'Tab');
  assert.equal(tab.defaultPrevented, false);
  assertExpanded(menu, true);
  h.keydown(menu.link, 'Escape', { defaultPrevented: true });
  assertExpanded(menu, true);
  assert.equal(h.document.activeElement, menu.link);
  assert.equal(menu.toggle.focusCalls, 0);
});

test('synthetic Escape from the menu does not steal focus from outside', () => {
  const h = harness();
  const menu = h.menu();
  const editor = h.document.append(new Element('textarea'));
  h.evaluate();
  h.click(menu.toggle);
  editor.focus();
  h.keydown(menu.link);
  assertExpanded(menu, false);
  assert.equal(h.document.activeElement, editor);
  assert.equal(menu.toggle.focusCalls, 0);
});

test('delegation and duplicate-init guard survive Turbo header replacement and cache restoration', () => {
  const h = harness();
  const original = h.menu();
  h.evaluate();
  h.evaluate();
  h.click(original.icon);
  assertExpanded(original, true);
  original.menu.remove();
  const replacement = h.menu();
  h.emit('turbo:load', h.document);
  h.evaluate();
  assert.equal(h.listeners.get('click').length, 1);
  assert.equal(h.listeners.get('keydown').length, 1);
  h.click(replacement.icon);
  assertExpanded(replacement, true);
  replacement.link.focus();
  h.keydown(replacement.link);
  assertExpanded(replacement, false);
  assert.equal(h.document.activeElement, replacement.toggle);
  replacement.menu.remove();
  h.document.append(original.menu); // Restore the cached header with its original open state.
  h.emit('turbo:load', h.document);
  h.evaluate();
  h.click(h.document);
  assertExpanded(original, false);
  h.click(original.toggle);
  assertExpanded(original, true);
  assert.equal(h.listeners.get('click').length, 1);
  assert.equal(h.listeners.get('keydown').length, 1);
});
