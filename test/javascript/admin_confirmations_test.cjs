const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_admin_confirmations.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*data-b270-admin-confirmations[^>]*>([\s\S]*?)<\/script>/i)[1];

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
    form(message = 'Start a new run and preserve all history?') {
      return {
        dataset: { b270AdminConfirm: message },
        matches: (selector) => selector === 'form[data-b270-admin-confirm]'
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

test('cancel blocks native restart submission in capture phase without Turbo', () => {
  const h = harness();
  const form = h.form();
  const event = h.submit(form);
  assert.deepEqual(h.prompts, [form.dataset.b270AdminConfirm]);
  assert.equal(h.listeners[0].capture, true);
  assert.equal(event.defaultPrevented, true);
  assert.equal(event.propagationStopped, true);
});

test('accepting allows the original submission without resubmitting', () => {
  const h = harness(true);
  const event = h.submit(h.form());
  assert.equal(h.prompts.length, 1);
  assert.equal(event.defaultPrevented, false);
  assert.equal(event.propagationStopped, false);
});

test('keyboard submission still confirms and cancellation allows another attempt', () => {
  const h = harness();
  const form = h.form();
  assert.equal(h.submit(form, { submitter: null }).defaultPrevented, true);
  assert.equal(h.submit(form).defaultPrevented, true);
  assert.equal(h.prompts.length, 2);
});

test('unrelated forms and the separate reader removal marker are not intercepted', () => {
  const h = harness();
  const event = h.submit({
    dataset: { b270RemoveReader: 'Remove reader?' },
    matches: (selector) => selector === 'form[data-b270-remove-reader]'
  });
  assert.equal(h.prompts.length, 0);
  assert.equal(event.defaultPrevented, false);
});

test('prevented submissions do not prompt', () => {
  const h = harness();
  h.submit(h.form(), { defaultPrevented: true });
  assert.equal(h.prompts.length, 0);
});

test('singleton survives Turbo visits and reads each new forms message', () => {
  const h = harness();
  h.submit(h.form('Restart?'));
  h.evaluate();
  h.submit(h.form('Mark as alumni?'));
  h.evaluate();
  h.submit(h.form('Reactivate?'));
  assert.equal(h.listeners.length, 1);
  assert.deepEqual(h.prompts, ['Restart?', 'Mark as alumni?', 'Reactivate?']);
});
