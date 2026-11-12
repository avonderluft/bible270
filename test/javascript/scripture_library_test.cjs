const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_scripture_library_ui.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const selector = 'details.b270-scripture-library-disclosure';
const dismissed = 'data-b270-scripture-preview-dismissed';

class Element {
  constructor(tag, parent = null, library = false) {
    this.tag = tag;
    this.parentElement = parent;
    this.library = library;
    this.open = false;
    this.attributes = new Set();
  }
  matches(query) { return query === selector ? this.tag === 'details' && this.library : query === this.tag; }
  closest(query) { return this.matches(query) ? this : this.parentElement?.closest(query) || null; }
  contains(node) { return node != null && (node === this || this.contains(node.parentElement)); }
  setAttribute(name) { this.attributes.add(name); }
  removeAttribute(name) { this.attributes.delete(name); }
}

function harness() {
  const listeners = new Map();
  const context = vm.createContext({ window: {}, document: {
    addEventListener(type, callback, capture = false) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push({ callback, capture });
    }
  } });
  const emit = (type, target, extra = {}) => {
    const event = { target, defaultPrevented: false, ...extra };
    for (const { callback } of listeners.get(type) || []) callback(event);
    return event;
  };
  const details = () => {
    const disclosure = new Element('details', null, true);
    const summary = new Element('summary', disclosure);
    const heading = new Element('strong', summary);
    const text = new Element('blockquote', disclosure);
    return { disclosure, summary, heading, text };
  };
  const evaluate = () => vm.runInContext(source, context, { filename, timeout: 1000 });
  evaluate();
  return { emit, details, evaluate, listeners,
    click(target, extra = {}) {
      const event = emit('click', target, extra);
      const disclosure = target.closest('summary')?.parentElement;
      if (disclosure?.matches(selector) && !event.defaultPrevented) {
        disclosure.open = !disclosure.open;
        emit('toggle', disclosure);
      }
      return event;
    }
  };
}

for (const target of ['summary', 'heading']) {
  test(`collapsing via ${target} suppresses previews without canceling native activation`, () => {
    const h = harness();
    const row = h.details();
    h.click(row[target]);
    assert.equal(row.disclosure.open, true);
    assert.equal(row.disclosure.attributes.has(dismissed), false);
    h.click(row[target]);
    assert.equal(row.disclosure.open, false);
    assert.equal(row.disclosure.attributes.has(dismissed), true);
    h.click(row[target]);
    assert.equal(row.disclosure.open, true);
    assert.equal(row.disclosure.attributes.has(dismissed), false);
  });
}

test('closing by keyboard activation also suppresses focus previews', () => {
  const h = harness();
  const row = h.details();
  row.disclosure.open = true;
  h.click(row.summary, { detail: 0 });
  assert.equal(row.disclosure.open, false);
  assert.equal(row.disclosure.attributes.has(dismissed), true);
});

test('programmatic toggles are handled in capture phase', () => {
  const h = harness();
  const { disclosure } = h.details();
  assert.equal(h.listeners.get('toggle')[0].capture, true);
  h.emit('toggle', disclosure);
  assert.equal(disclosure.attributes.has(dismissed), true);
  disclosure.open = true;
  h.emit('toggle', disclosure);
  assert.equal(disclosure.attributes.has(dismissed), false);
});

for (const type of ['pointerover', 'focusin']) {
  test(`fresh ${type} restores a preview, while movement within the same disclosure does not`, () => {
    const h = harness();
    const row = h.details();
    row.disclosure.setAttribute(dismissed, '');
    h.emit(type, row.heading, { relatedTarget: row.summary });
    assert.equal(row.disclosure.attributes.has(dismissed), true);
    h.emit(type, row.text, { relatedTarget: row.heading });
    assert.equal(row.disclosure.attributes.has(dismissed), true);
    h.emit(type, row.heading, { relatedTarget: new Element('button') });
    assert.equal(row.disclosure.attributes.has(dismissed), false);
    assert.equal(row.disclosure.open, false, 'preview must not expand the native disclosure');
  });
}

test('touch activation retains the native tap-to-expand and tap-to-collapse behavior', () => {
  const h = harness();
  const row = h.details();
  h.emit('pointerover', row.summary, { pointerType: 'touch', relatedTarget: null });
  h.click(row.summary, { pointerType: 'touch' });
  assert.equal(row.disclosure.open, true);
  h.click(row.summary, { pointerType: 'touch' });
  assert.equal(row.disclosure.open, false);
  assert.equal(row.disclosure.attributes.has(dismissed), true);
});

test('text clicks, action buttons, unrelated details, and prevented activation remain untouched', () => {
  const h = harness();
  const row = h.details();
  row.disclosure.open = true;
  h.click(row.text);
  h.click(new Element('button'));
  h.click(row.summary, { defaultPrevented: true });
  assert.equal(row.disclosure.open, true);
  assert.equal(row.disclosure.attributes.has(dismissed), false);
  const alumni = new Element('details');
  h.emit('toggle', alumni);
  h.emit('click', new Element('summary', alumni));
  assert.equal(alumni.attributes.has(dismissed), false);
});

test('different rows are independent and repeated scripts handle newly rendered Turbo rows once', () => {
  const h = harness();
  const first = h.details();
  first.disclosure.open = true;
  h.click(first.summary);
  h.evaluate();
  h.evaluate();
  const next = h.details();
  h.click(next.summary);
  assert.equal(next.disclosure.open, true);
  assert.equal(first.disclosure.attributes.has(dismissed), true);
  for (const handlers of h.listeners.values()) assert.equal(handlers.length, 1);
  h.emit('pointerover', {}, { relatedTarget: null });
  h.emit('focusin', {}, { relatedTarget: null });
  h.emit('toggle', {});
});
