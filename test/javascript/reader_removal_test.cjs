const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/admin/show.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*data-b270-reader-removal[^>]*>([\s\S]*?)<\/script>/i)[1];

function harness(confirmed = false) {
  const listeners = [];
  const prompts = [];
  const context = vm.createContext({
    document: { addEventListener: (type, callback, capture) => listeners.push({ type, callback, capture }) },
    window: { confirm: (message) => { prompts.push(message); return confirmed; } }
  });
  const evaluate = () => vm.runInContext(source, context, { filename, timeout: 1000 });
  evaluate();
  return {
    evaluate, listeners, prompts,
    form(message = 'Are you sure you want to remove Example Reader from the plan?') {
      return {
        dataset: { b270RemoveReader: message },
        matches: (selector) => selector === 'form[data-b270-remove-reader]'
      };
    },
    submit(form, properties = {}) {
      const event = {
        target: form, defaultPrevented: false, propagationStopped: false,
        preventDefault() { this.defaultPrevented = true; },
        stopImmediatePropagation() { this.propagationStopped = true; },
        ...properties
      };
      for (const { callback } of listeners.filter(({ type }) => type === 'submit')) callback(event);
      return event;
    }
  };
}

test('cancel blocks reader removal before Turbo or native submission', () => {
  const h = harness(false);
  const form = h.form();
  const event = h.submit(form);
  assert.deepEqual(h.prompts, [form.dataset.b270RemoveReader]);
  assert.equal(event.defaultPrevented, true);
  assert.equal(event.propagationStopped, true);
  assert.equal(h.listeners[0].capture, true);
});

test('confirm allows the original removal submission without submitting twice', () => {
  const h = harness(true);
  const event = h.submit(h.form());
  assert.equal(h.prompts.length, 1);
  assert.equal(event.defaultPrevented, false);
  assert.equal(event.propagationStopped, false);
});

test('keyboard submission without a submitter still requires confirmation', () => {
  const h = harness(false);
  const event = h.submit(h.form(), { submitter: null });
  assert.equal(h.prompts.length, 1);
  assert.equal(event.defaultPrevented, true);
});

test('unrelated admin forms are not intercepted', () => {
  const h = harness(false);
  const event = h.submit({ matches: () => false });
  assert.equal(h.prompts.length, 0);
  assert.equal(event.defaultPrevented, false);
  assert.equal(event.propagationStopped, false);
});

test('an already prevented submission does not prompt', () => {
  const h = harness(false);
  h.submit(h.form(), { defaultPrevented: true });
  assert.equal(h.prompts.length, 0);
});

test('Turbo visits and repeated script evaluation do not duplicate prompts or retain a reader', () => {
  const h = harness(false);
  h.submit(h.form('Remove first reader?'));
  h.evaluate();
  h.submit(h.form('Remove second reader?'));
  assert.equal(h.listeners.length, 1);
  assert.deepEqual(h.prompts, ['Remove first reader?', 'Remove second reader?']);
});

test('cancelling does not suppress confirmation on the next attempt', () => {
  const h = harness(false);
  const form = h.form();
  assert.equal(h.submit(form).defaultPrevented, true);
  assert.equal(h.submit(form).defaultPrevented, true);
  assert.equal(h.prompts.length, 2);
});
