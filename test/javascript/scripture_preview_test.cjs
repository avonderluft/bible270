const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { spawnSync } = require('node:child_process');
const vm = require('node:vm');
const { evaluateInChromium } = require('./helpers/chromium.cjs');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_scripture_preview_ui.html.erb');
const partial = readFileSync(filename, 'utf8');
const source = partial.replace(/<%[\s\S]*?%>/g, '').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const keys = ['reference', 'translation', 'text', 'attribution'];
const sample = {
  reference: 'John 3:16 <&> "reference"', translation: 'NASB95',
  text: 'First line <script>alert("never")</script> & <b>not HTML</b>\n  Second line\n\nLast line.',
  attribution: 'Credit & copyright <owner>\nAll rights reserved.'
};

function harness() {
  const listeners = new Map();
  const windowListeners = new Map();
  const queued = [];
  const dialogs = [];
  const calls = [];
  const add = (map) => (type, callback, capture = false) => {
    if (!map.has(type)) map.set(type, []);
    map.get(type).push({ callback, capture });
  };
  const document = {
    activeElement: null,
    addEventListener: add(listeners),
    getElementById(id) { return dialogs.find((dialog) => dialog.isConnected && dialog.getAttribute('id') === id) || null; }
  };
  const emit = (type, target = document, extra = {}, onWindow = false) => {
    const event = { type, target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...extra };
    for (const { callback } of (onWindow ? windowListeners : listeners).get(type) || []) callback(event);
    return event;
  };
  class Element {
    constructor(tag, attributes = {}) {
      this.tag = tag;
      this.attributes = new Map(Object.entries(attributes));
      this.children = [];
      this.parentElement = null;
      this.isConnected = true;
      this.hidden = false;
      this.textContent = '';
    }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    setAttribute(name, value) { this.attributes.set(name, value); }
    removeAttribute(name) { this.attributes.delete(name); }
    matches(query) {
      const match = query.match(/^(\w+)?(?:\[([^\]]+)\])?$/);
      return !!match && (!match[1] || this.tag === match[1]) && (!match[2] || this.attributes.has(match[2]));
    }
    closest(query) { return this.matches(query) ? this : this.parentElement?.closest(query) || null; }
    querySelector(query) {
      for (const child of this.children) {
        if (child.matches(query)) return child;
        const nested = child.querySelector(query);
        if (nested) return nested;
      }
      return null;
    }
    append(child) { child.parentElement = this; this.children.push(child); return child; }
    contains(node) { return !!node && (node === this || this.children.some((child) => child.contains(node))); }
    focus(options) { calls.push({ type: 'focus', target: this, options }); document.activeElement = this; }
    blur() { calls.push({ type: 'blur', target: this }); if (document.activeElement === this) document.activeElement = null; }
    getBoundingClientRect() { return { left: 100, top: 100, right: 500, bottom: 500 }; }
    set innerHTML(_) { throw new Error('HTML injection is forbidden'); }
  }
  const makeDialog = () => {
    const dialog = new Element('dialog', { id: 'b270-scripture-preview', 'data-b270-scripture-preview-dialog': '' });
    dialog.returnValue = '';
    Object.defineProperty(dialog, 'open', { get() { return dialog.attributes.has('open'); } });
    const close = dialog.append(new Element('button'));
    const art = dialog.append(new Element('figure', { 'data-b270-scripture-art': '' }));
    art.hidden = true;
    for (const key of keys) art.append(new Element(key === 'text' ? 'p' : 'span', { [`data-b270-scripture-${key}`]: '' }));
    dialog.showModal = () => {
      calls.push({ type: 'showModal' });
      dialog.nativeReturnFocus = document.activeElement;
      dialog.setAttribute('open', '');
      close.focus();
    };
    dialog.close = () => {
      if (!dialog.open) return;
      calls.push({ type: 'close' });
      dialog.removeAttribute('open');
      // Model native restoration so navigation tests catch implicit refocusing.
      if (dialog.nativeReturnFocus?.isConnected && !dialog.nativeReturnFocus.inert) dialog.nativeReturnFocus.focus({ preventScroll: true });
      queued.push(() => { if (dialog.isConnected) emit('close', dialog); });
    };
    dialogs.push(dialog);
    return dialog;
  };
  const trigger = (data = sample, disabled = false) => {
    const button = new Element('button', {
      'data-b270-scripture-preview': '', 'aria-controls': 'b270-scripture-preview',
      'aria-label': `Preview ${data.reference}`
    });
    for (const key of keys) if (data[key] != null) button.setAttribute(`data-b270-preview-${key}`, data[key]);
    button.rowDisabled = disabled; // Disabled library text is not a disabled Preview button.
    button.append(new Element('span'));
    return button;
  };
  const forbidden = (name) => () => { throw new Error(`${name} is forbidden`); };
  const sandbox = { document, addEventListener: add(windowListeners) };
  for (const name of ['fetch', 'setTimeout', 'setInterval', 'requestAnimationFrame', 'XMLHttpRequest', 'WebSocket']) sandbox[name] = forbidden(name);
  for (const name of ['sessionStorage', 'localStorage']) Object.defineProperty(sandbox, name, { get: forbidden(name) });
  sandbox.window = sandbox;
  const context = vm.createContext(sandbox);
  const evaluate = () => vm.runInContext(source, context, { filename, timeout: 1000 });
  const dialog = makeDialog();
  const flushClose = () => { while (queued.length) queued.shift()(); };
  evaluate();
  return {
    context, document, dialog, makeDialog, trigger, evaluate, emit, calls, listeners, windowListeners, flushClose,
    click: (target, extra) => emit('click', target, extra),
    field: (key, root = dialog) => root.querySelector(`[data-b270-scripture-${key}]`),
    art: (root = dialog) => root.querySelector('[data-b270-scripture-art]'),
    dismiss() { dialog.close(); flushClose(); },
    cancel() {
      // Simulate the native cancel default action, not an actual Escape keypress.
      const event = emit('cancel', dialog);
      if (!event.defaultPrevented) dialog.close();
      flushClose();
    }
  };
}

function assertClear(h, dialog = h.dialog) {
  assert.equal(dialog.open, false);
  assert.equal(dialog.getAttribute('open'), null);
  assert.equal(dialog.returnValue, '');
  assert.equal(h.art(dialog).hidden, true);
  for (const key of keys) assert.equal(h.field(key, dialog).textContent, '');
  for (const key of ['translation', 'attribution']) assert.equal(h.field(key, dialog).hidden, true);
}

function assertData(h, data = sample, dialog = h.dialog) {
  assert.equal(dialog.open, true);
  assert.equal(h.art(dialog).hidden, false);
  for (const key of keys) {
    const omit = data.translation === 'OTHER' && ['translation', 'attribution'].includes(key);
    assert.equal(h.field(key, dialog).textContent, omit ? '' : data[key] || '');
    if (['translation', 'attribution'].includes(key)) assert.equal(h.field(key, dialog).hidden, omit || !data[key]?.trim());
  }
}

test('partial renders one native labelled dialog and the actual shared readerboard once', () => {
  assert.match(partial, /<dialog id="b270-scripture-preview" class="b270-scripture-preview" aria-label="Scripture frame preview" data-b270-scripture-preview-dialog>/);
  assert.match(partial, /<form method="dialog" class="b270-scripture-preview-close">/);
  assert.match(partial, /<button type="submit" class="b270-linkbtn" aria-label="Close preview" autofocus>×<\/button>/);
  assert.equal((partial.match(/render partial: "bible270\/shared\/scripture_frame", locals: \{ frame: nil \}/g) || []).length, 1);
  assert.match(partial, /<script nonce="<%= content_security_policy_nonce %>" data-b270-scripture-preview-ui>/);
  assert.doesNotMatch(source, /\b(?:fetch|sessionStorage|localStorage|setTimeout|setInterval|requestAnimationFrame|innerHTML|insertAdjacentHTML|XMLHttpRequest)\b/);
});

for (const disabled of [false, true]) {
  test(`${disabled ? 'disabled' : 'enabled'} text previews exact strings, newlines and metacharacters without HTML or external work`, () => {
    const h = harness();
    const button = h.trigger(sample, disabled);
    const event = h.click(button.children[0]);
    assert.equal(event.defaultPrevented, true);
    assertData(h);
    assert.equal(h.calls.filter((call) => call.type === 'showModal').length, 1);
  });
}

test('OTHER quotations omit both translation and attribution; subsequent Scripture restores them', () => {
  const h = harness();
  const quote = { ...sample, reference: 'A quotation', translation: 'OTHER' };
  h.click(h.trigger(quote));
  assertData(h, quote);
  h.click(h.trigger(sample));
  assertData(h);
  assert.equal(h.calls.filter((call) => call.type === 'showModal').length, 1);
});

for (const attribution of [undefined, '', ' \n ']) {
  test(`missing/blank attribution ${JSON.stringify(attribution)} stays hidden without stale credit`, () => {
    const h = harness();
    h.click(h.trigger());
    const next = { ...sample, attribution };
    h.click(h.trigger(next));
    assertData(h, next);
  });
}

for (const method of ['dismiss', 'cancel']) {
  test(`${method === 'cancel' ? 'native cancel default action (Escape simulation)' : 'normal close'} clears fields and restores the invoking button without scrolling`, () => {
    const h = harness();
    const button = h.trigger();
    h.click(button);
    h.dialog.returnValue = 'stale';
    h[method]();
    assertClear(h);
    assert.equal(h.document.activeElement, button);
    const last = h.calls.at(-1);
    assert.equal(last.type, 'focus');
    assert.equal(last.options.preventScroll, true);
  });
}

test('an already prevented activation is untouched, including while another preview is open', () => {
  const h = harness();
  h.click(h.trigger(), { defaultPrevented: true });
  assert.equal(h.dialog.open, false);
  const button = h.trigger();
  h.click(button);
  h.click(h.trigger({ ...sample, text: 'Do not replace' }), { defaultPrevented: true });
  assertData(h);
  h.dismiss();
  assert.equal(h.document.activeElement, button);
});

test('missing targets, unrelated targets, detached buttons, incomplete markup and unsupported native dialogs are safe no-ops', () => {
  const h = harness();
  h.click({});
  const missing = h.trigger();
  missing.setAttribute('aria-controls', 'missing');
  assert.equal(h.click(missing).defaultPrevented, false);
  const detached = h.trigger();
  detached.isConnected = false;
  h.click(detached);
  h.dialog.isConnected = false;
  h.click(h.trigger());
  h.dialog.isConnected = true;
  const showModal = h.dialog.showModal;
  h.dialog.showModal = undefined;
  h.click(h.trigger());
  h.dialog.showModal = showModal;
  h.field('text').removeAttribute('data-b270-scripture-text');
  h.click(h.trigger());
  assert.equal(h.calls.length, 0);
  assert.equal(h.dialog.open, false);
});

test('showModal failure clears populated data without restoring focus', () => {
  const h = harness();
  h.dialog.showModal = () => { throw new Error('InvalidStateError'); };
  h.click(h.trigger());
  assertClear(h);
  assert.equal(h.calls.filter((call) => call.type === 'focus').length, 0);
});

test('only an actual backdrop click that started outside dismisses, never dialog padding or inside-to-outside drags', () => {
  const h = harness();
  h.click(h.trigger());
  const pointer = (target, x, y) => h.emit('pointerdown', target, { clientX: x, clientY: y });
  const click = (target, x, y, extra) => h.click(target, { clientX: x, clientY: y, ...extra });
  pointer(h.dialog, 101, 101); // Padding: target is dialog, but coordinates are inside.
  click(h.dialog, 101, 101);
  assert.equal(h.dialog.open, true);
  pointer(h.field('text'), 200, 200);
  click(h.dialog, 90, 90);
  assert.equal(h.dialog.open, true);
  click(h.dialog, 90, 90); // No outside pointerdown.
  assert.equal(h.dialog.open, true);
  pointer(h.dialog, 90, 90);
  h.emit('pointercancel', h.dialog);
  click(h.dialog, 90, 90);
  assert.equal(h.dialog.open, true);
  pointer(h.dialog, 90, 90);
  click(h.dialog, 90, 90, { defaultPrevented: true });
  assert.equal(h.dialog.open, true);
  click(h.dialog, 90, 90); // Prevented activation must consume the old pointerdown.
  assert.equal(h.dialog.open, true);
  pointer(h.dialog, 90, 90);
  click(h.dialog, 90, 90);
  h.flushClose();
  assertClear(h);
});

test('switching rows updates an open dialog without a close/show cycle and restores the newest invoking button', () => {
  const h = harness();
  h.click(h.trigger());
  const next = { ...sample, reference: 'Next row', text: 'Disabled default passage', attribution: null };
  const button = h.trigger(next, true);
  h.click(button);
  assertData(h, next);
  assert.deepEqual(h.calls.filter((call) => ['showModal', 'close'].includes(call.type)).map((call) => call.type), ['showModal']);
  h.dismiss();
  assert.equal(h.document.activeElement, button);
});

test('a queued close cannot destroy a reopened dialog or restore focus to an older trigger', () => {
  const h = harness();
  h.click(h.trigger());
  h.dialog.close(); // Native close events are queued, not synchronous.
  const next = { ...sample, text: 'New session' };
  const button = h.trigger(next);
  h.click(button);
  h.flushClose();
  assertData(h, next);
  assert.notEqual(h.document.activeElement, button);
  h.dismiss();
  assert.equal(h.document.activeElement, button);
});

for (const type of ['turbo:before-cache', 'turbo:before-render', 'pagehide']) {
  test(`${type} closes, clears and never explicitly restores focus; replacement Turbo DOM works`, () => {
    const h = harness();
    const button = h.trigger();
    button.focus();
    h.click(button);
    const focusCount = h.calls.filter((call) => call.type === 'focus').length;
    h.emit(type, type === 'pagehide' ? h.context : h.document, {}, type === 'pagehide');
    assertClear(h);
    h.flushClose();
    assert.equal(h.calls.filter((call) => call.type === 'focus').length, focusCount);
    h.dialog.isConnected = false;
    button.isConnected = false;
    const nextDialog = h.makeDialog();
    h.evaluate();
    h.click(h.trigger());
    assertData(h, sample, nextDialog);
    h.emit('close', h.dialog); // Late event from the detached root.
    assertData(h, sample, nextDialog);
  });
}

test('navigation after switching rows suppresses the original native focus target, not just the newest trigger', () => {
  const h = harness();
  const original = h.trigger();
  original.focus();
  h.click(original);
  const next = h.trigger({ ...sample, text: 'Next row' });
  h.click(next);
  const focusCount = h.calls.filter((call) => call.type === 'focus').length;
  h.emit('turbo:before-render');
  h.flushClose();
  assertClear(h);
  assert.equal(h.calls.filter((call) => call.type === 'focus').length, focusCount);
  assert.equal(original.inert, undefined);
});

test('activating replacement DOM also clears an old detached dialog without lifecycle delivery', () => {
  const h = harness();
  h.click(h.trigger());
  h.dialog.isConnected = false;
  const next = h.makeDialog();
  h.click(h.trigger({ ...sample, text: 'Replacement row' }));
  assertClear(h);
  h.flushClose();
  assertData(h, { ...sample, text: 'Replacement row' }, next);
});

test('detached triggers and dialog roots are safely cleaned without focus restoration', () => {
  for (const detach of ['trigger', 'dialog', 'both']) {
    const h = harness();
    const button = h.trigger();
    h.click(button);
    const count = h.calls.length;
    if (detach !== 'dialog') button.isConnected = false;
    if (detach !== 'trigger') h.dialog.isConnected = false;
    h.dismiss();
    // Detached close events cannot reach the delegated document listener.
    // The lifecycle reset must still clean the retained, detached root safely.
    if (detach !== 'trigger') h.emit('turbo:before-cache');
    assertClear(h);
    assert.equal(h.calls.slice(count).filter((call) => call.type === 'focus').length, 0);
    h.context.Bible270ScripturePreview.reset();
  }
});

test('repeated script evaluation resets state and binds one delegated handler per event, including new DOM', () => {
  const h = harness();
  const singleton = h.context.Bible270ScripturePreview;
  h.click(h.trigger());
  h.evaluate();
  h.evaluate();
  assertClear(h);
  h.flushClose();
  assert.equal(h.context.Bible270ScripturePreview, singleton);
  for (const handlers of [...h.listeners.values(), ...h.windowListeners.values()]) assert.equal(handlers.length, 1);
  assert.equal(h.listeners.get('close')[0].capture, true);
  h.dialog.isConnected = false;
  const next = h.makeDialog();
  h.click(h.trigger());
  assertData(h, sample, next);
});

test('real native modal preview follows six themes, fits narrow screens and scrolls long text (optional Chromium)', { timeout: 45000 }, async (t) => {
  const browser = process.env.CHROME_BIN || 'chromium';
  const probe = spawnSync(browser, ['--version'], { timeout: 15000, encoding: 'utf8' });
  if (!process.env.CHROME_BIN && probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; VM and markup checks still run');
  assert.ifError(probe.error);
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  const figure = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_scripture_frame.html.erb'), 'utf8').replace(/<%[\s\S]*?%>/g, '');
  // Use the actual partial markup, substituting only its one server-rendered figure.
  const markup = partial.replace(/<%= render partial: "bible270\/shared\/scripture_frame", locals: \{ frame: nil \} %>/, figure)
    .replace(/<%[\s\S]*?%>/g, '').replace(/<script\b[\s\S]*?<\/script>/i, '');
  const browserCheck = async function(styles, figure, markup, source, sample) {
    const failures = [];
    const surfaces = new Set();
    let scenarios = 0;
    const check = (condition, message) => { if (!condition) failures.push(message); };
    const paint = (win) => new Promise((resolve) => win.requestAnimationFrame(() => win.requestAnimationFrame(resolve)));
    for (const width of [240, 360, 1024]) {
      const viewport = document.createElement('iframe');
      viewport.style.cssText = `display:block;border:0;width:${width}px;height:600px`;
      document.body.append(viewport);
      const doc = viewport.contentDocument;
      doc.open();
      doc.write(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head><body class="b270"><main class="b270-wrap"><section class="b270-panel" id="b270-scripture-frames"><button type="button" class="b270-linkbtn" data-b270-scripture-preview aria-controls="b270-scripture-preview">Preview disabled text</button><button type="button" id="outside">Background action</button></section></main>${markup}<div class="b270-scripture-popup" id="reader-reference" style="left:-10000px;top:0">${figure}</div></body></html>`);
      doc.close();
      const win = viewport.contentWindow;
      let externalWork = 0;
      const forbidden = () => { externalWork++; throw new Error('Preview must be client-only'); };
      win.fetch = win.setTimeout = win.setInterval = forbidden;
      for (const key of ['sessionStorage', 'localStorage']) Object.defineProperty(win, key, { get: forbidden });
      // A sentinel models the independent header rotation state; preview must not touch it.
      const rotation = win.Bible270ScriptureFrame = { previousID: 'reader-frame-7' };
      win.Function(source)();
      const dialog = doc.querySelector('dialog');
      const trigger = doc.querySelector('[data-b270-scripture-preview]');
      const close = dialog.querySelector('form[method="dialog"] button');
      const art = dialog.querySelector('figure');
      const reader = doc.querySelector('#reader-reference figure');
      const field = (key) => dialog.querySelector(`[data-b270-scripture-${key}]`);
      const css = (element) => win.getComputedStyle(element);
      const data = (frame) => {
        for (const key of ['reference', 'translation', 'text', 'attribution']) {
          if (frame[key] == null) trigger.removeAttribute(`data-b270-preview-${key}`);
          else trigger.setAttribute(`data-b270-preview-${key}`, frame[key]);
        }
      };
      data(sample);
      for (const theme of ['light', 'sage', 'mist', 'dark', 'dark_green', 'dark_blue']) {
        scenarios++;
        const name = `${theme}/${width}px`;
        doc.body.setAttribute('data-display-mode', theme);
        doc.documentElement.setAttribute('data-b270-display-mode', theme);
        trigger.focus();
        trigger.click();
        check(dialog.open && dialog.matches(':modal'), `${name}: native showModal enters the modal top layer`);
        check(doc.activeElement === close, `${name}: native autofocus starts inside the dialog`);
        doc.querySelector('#outside').focus();
        check(dialog.contains(doc.activeElement), `${name}: native modality makes background controls inert to focus`);
        for (const key of ['reference', 'translation', 'text', 'attribution']) check(field(key).textContent === sample[key], `${name}: exact ${key}, including newlines and markup characters`);
        check(!art.querySelector('script,b'), `${name}: passage never becomes HTML`);
        const rect = dialog.getBoundingClientRect();
        check(Math.abs(rect.width - Math.min(512, width - 24)) <= 1, `${name}: dialog width is min(32rem, viewport minus 24px), got ${rect.width}`);
        const closeRect = close.getBoundingClientRect();
        check(closeRect.right <= rect.right && closeRect.left >= rect.right - 56 && closeRect.top >= rect.top && closeRect.top < rect.top + 44, `${name}: close form stays at the dialog's top right`);
        check(rect.left >= 11 && rect.right <= width - 11 && rect.top >= 11 && rect.bottom <= 589, `${name}: dialog stays within viewport minus 24px (${rect.left},${rect.right},${rect.top},${rect.bottom})`);
        check(doc.documentElement.scrollWidth <= width, `${name}: no horizontal page overflow`);
        for (const selector of ['.b270-scripture-art__mat', '.b270-scripture-art__verse', '.b270-scripture-art__verse p', '.b270-scripture-art__reference', '.b270-scripture-art__translation', '.b270-scripture-art__attribution']) {
          for (const property of ['color', 'backgroundColor', 'fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'whiteSpace', 'padding', 'borderTopColor']) {
            check(css(art.querySelector(selector))[property] === css(reader.querySelector(selector))[property], `${name}: preview matches reader ${selector}/${property}`);
          }
        }
        const mat = css(art.querySelector('.b270-scripture-art__mat')).backgroundColor;
        check(css(dialog).backgroundColor === mat, `${name}: dialog surface matches readerboard mat`);
        if (theme === 'sage') check(mat === 'rgb(209, 226, 234)', `${name}: Meadow keeps the sky-blue art surface`);
        surfaces.add(mat);
        close.click(); // Real method=dialog default action, not dialog.close().
        await paint(win);
        check(!dialog.open && doc.activeElement === trigger, `${name}: native X form closes and restores invoking Preview focus`);
        check(art.hidden && field('text').textContent === '' && dialog.returnValue === '', `${name}: native close clears stale content`);
      }
      const nextTrigger = trigger.cloneNode(true);
      nextTrigger.setAttribute('data-b270-preview-text', 'Another disabled row');
      trigger.after(nextTrigger);
      trigger.focus();
      trigger.click();
      nextTrigger.click(); // Programmatic activation can select an inert background row.
      await paint(win);
      check(dialog.matches(':modal') && field('text').textContent === 'Another disabled row', `${width}px: switching rows updates the same open native modal`);
      close.click();
      await paint(win);
      check(doc.activeElement === nextTrigger, `${width}px: switching rows restores the latest invoking Preview`);
      trigger.click();
      dialog.close();
      nextTrigger.click(); // Reopen before the previous close event is delivered.
      await paint(win);
      check(dialog.open && field('text').textContent === 'Another disabled row', `${width}px: queued native close cannot erase a reopened preview`);
      close.click();
      await paint(win);
      nextTrigger.remove();
      data({ ...sample, text: 'Long text preserves newlines and scrolls.\n'.repeat(110) }); // >4k characters.
      trigger.click();
      const scrollArea = [dialog, art].find((element) => element.scrollHeight > element.clientHeight && /auto|scroll/.test(css(element).overflowY));
      check(!!scrollArea, `${width}px: 4k passage has a real scrolling region`);
      if (scrollArea) { scrollArea.scrollTop = 80; check(scrollArea.scrollTop === 80, `${width}px: long passage can scroll`); }
      let rect = dialog.getBoundingClientRect();
      check(rect.height <= 577 && rect.top >= 11 && rect.bottom <= 589, `${width}px: long passage stays vertically bounded`);
      const pointerClick = (startX, startY, endX, endY, start = dialog) => {
        start.dispatchEvent(new win.PointerEvent('pointerdown', { bubbles: true, clientX: startX, clientY: startY }));
        dialog.dispatchEvent(new win.MouseEvent('click', { bubbles: true, clientX: endX, clientY: endY }));
      };
      pointerClick(rect.left + 1, rect.top + 1, rect.left + 1, rect.top + 1);
      check(dialog.open, `${width}px: clicking dialog padding does not dismiss`);
      pointerClick(rect.left + 5, rect.top + 5, rect.left - 2, rect.top - 2, art);
      check(dialog.open, `${width}px: dragging from inside to backdrop does not dismiss`);
      pointerClick(rect.left - 2, rect.top - 2, rect.left - 2, rect.top - 2);
      await paint(win);
      check(!dialog.open && doc.activeElement === trigger, `${width}px: synthetic pointer/click path dismisses only actual backdrop coordinates`);
      trigger.click();
      check(dialog.scrollTop === 0, `${width}px: reopening a scrolled passage starts at the top`);
      close.click();
      await paint(win);
      data({ ...sample, translation: 'OTHER' });
      trigger.click();
      check(field('translation').hidden && field('attribution').hidden && field('translation').textContent === '' && field('attribution').textContent === '', `${width}px: quotations omit translation and credit`);
      // Dispatch cancel and perform its native default action explicitly: this is
      // Escape semantics coverage, not a claim to send a trusted Escape key.
      if (dialog.dispatchEvent(new win.Event('cancel', { cancelable: true }))) dialog.close();
      await paint(win);
      check(!dialog.open && doc.activeElement === trigger, `${width}px: cancel/default-close restores focus`);
      data(sample);
      trigger.click();
      doc.dispatchEvent(new win.Event('turbo:before-cache'));
      await paint(win);
      check(!dialog.open && art.hidden && field('text').textContent === '', `${width}px: Turbo cleanup leaves no open/stale preview`);
      check(doc.activeElement !== trigger, `${width}px: navigation cleanup does not restore departing Preview focus`);
      const replacement = dialog.cloneNode(true);
      dialog.remove();
      doc.body.append(replacement);
      win.Function(source)(); // A Turbo render re-evaluates the script with a new root.
      trigger.focus();
      trigger.click();
      check(replacement.matches(':modal') && replacement.querySelector('[data-b270-scripture-text]').textContent === sample.text, `${width}px: singleton delegation handles replacement Turbo DOM`);
      trigger.remove();
      replacement.remove();
      doc.dispatchEvent(new win.Event('turbo:before-render'));
      await paint(win);
      check(!replacement.open && replacement.querySelector('figure').hidden && replacement.querySelector('[data-b270-scripture-text]').textContent === '', `${width}px: detached dialog and trigger still clean up safely`);
      check(externalWork === 0 && win.Bible270ScriptureFrame === rotation && rotation.previousID === 'reader-frame-7', `${width}px: no fetch, timers, storage or header rotation changes`);
      viewport.remove();
    }
    check(surfaces.size === 6, 'all six themes retain distinct inherited frame surfaces');
    return { failures, scenarios };
  };
  const expression = `(${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(figure)},${JSON.stringify(markup)},${JSON.stringify(source)},${JSON.stringify(sample)})`;
  const report = await evaluateInChromium(browser, expression, { timeout: 30000 });
  assert.deepEqual(report.failures, [], report.failures.join('\n'));
  assert.equal(report.scenarios, 18);
});
