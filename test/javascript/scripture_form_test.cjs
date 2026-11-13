const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/admin_scripture_frames/_form.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];

function harness(value = 'NASB95') {
  const listeners = new Map();
  const forms = [];
  const document = {
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(callback);
    },
    querySelectorAll(selector) {
      assert.equal(selector, 'form[data-b270-scripture-form]');
      return forms;
    }
  };
  const context = vm.createContext({ window: {}, document });
  const addForm = (value) => {
    const label = { textContent: '' };
    const credit = { textContent: '', hidden: false };
    const select = { value, name: 'scripture_frame[translation]', selectedOptions: [{ dataset: { credit: 'NASB 1995 © The Lockman Foundation.' } }],
      closest: () => form };
    const form = { querySelector(selector) {
      if (selector === '[name="scripture_frame[translation]"]') return select;
      if (selector === 'label[for="scripture_frame_reference"]') return label;
      if (selector === '#b270-scripture-frame-credit') return credit;
      assert.fail(`Unexpected selector: ${selector}`);
    } };
    forms.push(form);
    return { form, select, label, credit };
  };
  const fields = addForm(value);
  const evaluate = () => vm.runInContext(source, context, { filename, timeout: 1000 });
  const emit = (type, target) => (listeners.get(type) || []).forEach((callback) => callback({ target }));
  evaluate();
  return { ...fields, addForm, evaluate, emit, listeners };
}

test('quotation labels and credit visibility initialize on edit and after validation errors', () => {
  const h = harness('OTHER');
  assert.equal(h.label.textContent, 'Author / source');
  assert.equal(h.credit.hidden, true);
  assert.equal(h.credit.textContent, '');
});

test('changing between Scripture and quotation updates labels and automatic credits', () => {
  const h = harness();
  assert.equal(h.label.textContent, 'Reference');
  assert.equal(h.credit.hidden, false);
  assert.equal(h.credit.textContent, 'Attribution: NASB 1995 © The Lockman Foundation.');
  h.select.value = 'OTHER';
  h.emit('change', h.select);
  assert.equal(h.label.textContent, 'Author / source');
  assert.equal(h.credit.hidden, true);
  assert.equal(h.credit.textContent, '');
  h.select.value = 'NKJV';
  h.select.selectedOptions = [{ dataset: { credit: 'NKJV © 1982 Thomas Nelson.' } }];
  h.emit('change', h.select);
  assert.equal(h.label.textContent, 'Reference');
  assert.equal(h.credit.hidden, false);
  assert.equal(h.credit.textContent, 'Attribution: NKJV © 1982 Thomas Nelson.');
});

test('public domain and blank choices do not retain another translation credit', () => {
  const h = harness();
  for (const value of ['KJV', '']) {
    h.select.value = value;
    h.select.selectedOptions = [{ dataset: {} }];
    h.emit('change', h.select);
    assert.equal(h.credit.hidden, false);
    assert.equal(h.credit.textContent, 'Attribution: No attribution is configured for this translation.');
  }
});

test('repeated scripts and Turbo navigation initialize new forms without duplicate listeners', () => {
  const h = harness();
  h.evaluate();
  assert.equal(h.listeners.get('change').length, 1);
  assert.equal(h.listeners.get('turbo:load').length, 1);
  const next = h.addForm('OTHER');
  h.emit('turbo:load');
  assert.equal(next.label.textContent, 'Author / source');
  assert.equal(next.credit.hidden, true);
  assert.equal(h.label.textContent, 'Reference');
  h.emit('change', { name: 'scripture_frame[text]', closest: () => next.form });
  h.emit('change', { closest: () => null });
  assert.equal(next.label.textContent, 'Author / source');
});
