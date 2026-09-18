const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_markdown_toolbar.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const id = 'Abc_123-xyZ';
const marker = `[YouTube video](https://www.youtube.com/watch?v=${id} "bible270-video")`;

function element(dataset = {}) {
  const listeners = new Map();
  return {
    dataset,
    hidden: true,
    attributes: {},
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(callback);
    },
    dispatchEvent(event) {
      for (const callback of listeners.get(event.type) || []) callback(event);
      return true;
    },
    setAttribute(name, value) { this.attributes[name] = value; },
    focus() { this.focused = true; },
    setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  };
}

function harness(answer, value = 'beforeSELECTafter', start = 6, end = 12, name = '') {
  const textarea = Object.assign(element(), { value, selectionStart: start, selectionEnd: end });
  const format = { value: 'plain' };
  const button = element({ b270MarkdownAction: 'video' });
  const toolbar = element();
  toolbar.querySelectorAll = (selector) => {
    assert.equal(selector, '[data-b270-markdown-action]');
    return [button];
  };
  const nodes = new Map([
    ["textarea[name='comment[body]']", textarea],
    ['[data-b270-body-format]', format],
    ['[data-b270-markdown-toolbar]', toolbar],
    ...['editor-utilities', 'formatting-drawer', 'formatting-toggle', 'preview-toggle']
      .map((name) => [`[data-b270-${name}]`, element()])
  ]);
  const editor = element({ b270EditorKey: 'test-editor' });
  editor.closest = (selector) => { assert.equal(selector, 'form'); return null; };
  editor.querySelector = (selector) => {
    assert.ok(nodes.has(selector), `Unexpected editor selector: ${selector}`);
    return nodes.get(selector);
  };
  const document = element();
  document.documentElement = element();
  document.querySelectorAll = (selector) => {
    assert.equal(selector, '[data-b270-markdown-editor]');
    return [editor];
  };
  const prompts = [];
  const alerts = [];
  const inputs = [];
  textarea.addEventListener('input', (event) => inputs.push({
    type: event.type, bubbles: event.bubbles, value: textarea.value, format: format.value
  }));
  const window = Object.assign(element(), {
    prompt(message) { prompts.push(message); return prompts.length === 1 ? answer : name; },
    alert(message) { alerts.push(message); }
  });
  class MutationObserver { observe() {} }
  const context = vm.createContext({ window, document, URL, Event, MutationObserver,
    fetch() { assert.fail('Video insertion must not make a network request'); } });
  const evaluate = () => vm.runInContext(source, context, { filename, timeout: 1000 });
  evaluate(); // Exercise scan -> initialize -> actual registered toolbar event handler.
  assert.equal(editor.dataset.b270MarkdownReady, 'true');
  assert.equal(nodes.get('[data-b270-editor-utilities]').hidden, false);
  return { textarea, format, prompts, alerts, inputs, evaluate,
    click: () => button.dispatchEvent(new Event('click')) };
}

const urls = [
  `https://www.youtube.com/watch?v=${id}&t=30`,
  `http://youtube.com/watch?v=${id}`,
  `https://m.youtube.com/watch?v=${id}`,
  `https://youtu.be/${id}?si=share`,
  `https://www.youtu.be/${id}`,
  `https://www.youtube.com/shorts/${id}`,
  `https://www.youtube.com/live/${id}`,
  `https://www.youtube.com/embed/${id}`,
  `  https://youtu.be/${id}  `
];

for (const url of urls) {
  test(`Video click canonicalizes ${JSON.stringify(url)} and replaces selection as an isolated block`, () => {
    const h = harness(url);
    h.click();
    const value = `before\n\n${marker}\n\nafter`;
    const caret = value.length - 'after'.length;
    assert.equal(h.textarea.value, value);
    assert.equal(h.textarea.selectionStart, caret);
    assert.equal(h.textarea.selectionEnd, caret);
    assert.equal(h.textarea.focused, true);
    assert.equal(h.format.value, 'markdown');
    assert.deepEqual(h.inputs, [{ type: 'input', bubbles: true, value, format: 'markdown' }]);
    assert.equal(h.prompts.length, 2);
    assert.deepEqual(h.alerts, []);
  });
}

for (const [value, caret, expected] of [
  ['', 0, `${marker}\n\n`],
  ['after', 0, `${marker}\n\nafter`],
  ['before', 6, `before\n\n${marker}\n\n`]
]) {
  test(`Video insertion at caret ${caret} in ${JSON.stringify(value)} preserves blank-line isolation`, () => {
    const h = harness(`https://youtu.be/${id}`, value, caret, caret);
    h.evaluate(); // A repeated partial evaluation must not register duplicate click handlers.
    h.click();
    assert.equal(h.textarea.value, expected);
    assert.equal(h.prompts.length, 2);
    assert.equal(h.inputs.length, 1);
  });
}

test('Video name is normalized and punctuation encoded as literal link text', () => {
  const h = harness(`https://youtu.be/${id}`, '', 0, 0, '  Grace [today] & <hope> *now*\n');
  h.click();
  assert.equal(h.textarea.value,
    `[Grace &#91;today&#93; &#38; &#60;hope&#62; &#42;now&#42;](https://www.youtube.com/watch?v=${id} "bible270-video")\n\n`);
  assert.equal(h.inputs.length, 1);
});

test('Blank video name keeps the generic label', () => {
  const h = harness(`https://youtu.be/${id}`, '', 0, 0, '   ');
  h.click();
  assert.equal(h.textarea.value, `${marker}\n\n`);
});

test('Cancelling the name prompt leaves the draft unchanged', () => {
  const h = harness(`https://youtu.be/${id}`, 'draft', 0, 0, null);
  h.click();
  assert.equal(h.textarea.value, 'draft');
  assert.equal(h.format.value, 'plain');
  assert.deepEqual(h.inputs, []);
  assert.equal(h.prompts.length, 2);
});

const rejected = [
  null, '', '   ', 'not a URL',
  `https://youtube.com.evil.example/watch?v=${id}`,
  `https://evil.example/watch?v=${id}`,
  `https://user:password@youtube.com/watch?v=${id}`,
  `https://youtube.com:8443/watch?v=${id}`,
  `ftp://youtube.com/watch?v=${id}`,
  `//youtube.com/watch?v=${id}`,
  `https://youtube.com/watch?v=${id}&v=${id}`,
  `https://youtu.be/${id}/extra`,
  `https://youtu.be/${id}?bad=%ZZ`,
  `https://youtu.be/${id}?bad=has space`,
  `https://youtu.be/${id}?bad=has\nnewline`,
  'https://youtube.com/watch?v=short',
  'https://youtube.com/watch?v=abcdefghij!'
];

for (const url of rejected) {
  test(`cancelled/invalid Video prompt ${JSON.stringify(url)} leaves editor untouched`, () => {
    const h = harness(url);
    h.click();
    assert.equal(h.textarea.value, 'beforeSELECTafter');
    assert.equal(h.textarea.selectionStart, 6);
    assert.equal(h.textarea.selectionEnd, 12);
    assert.equal(h.textarea.focused, undefined);
    assert.equal(h.format.value, 'plain');
    assert.deepEqual(h.inputs, []);
    assert.equal(h.prompts.length, 1);
    assert.equal(h.alerts.length, url ? 1 : 0);
  });
}
