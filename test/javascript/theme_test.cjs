const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');

const filename = resolve(__dirname, '../../app/views/bible270/shared/_theme_ui.html.erb');
const source = readFileSync(filename, 'utf8').replace(/<%[\s\S]*?%>/g, '')
  .match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
const selector = 'select[data-b270-theme-url]';

class Select {
  constructor(dataset = {}) {
    this.dataset = { ...dataset };
    this.value = 'earth';
    this.disabled = false;
    this.isConnected = true;
    this.attributes = {};
  }
  matches(value) {
    assert.equal(value, selector);
    return Object.hasOwn(this.dataset, 'b270ThemeUrl');
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  removeAttribute(name) { delete this.attributes[name]; }
}

function harness({ apply = 'true', url = '/profile/theme' } = {}) {
  const select = new Select({
    b270ThemeUrl: url, b270ThemeApply: apply, b270SavedTheme: 'parchment'
  });
  const selects = [select];
  const region = { textContent: '', dataset: {} };
  const headerRegion = { textContent: '', dataset: {} };
  const regions = { 'b270-theme-status': region, 'b270-header-theme-status': headerRegion };
  const meta = { content: 'old-token' };
  const inputs = [{ value: 'old-token' }, { value: 'old-token' }];
  const fallbacks = [{ hidden: false }];
  const listeners = new Map();
  const requests = [];
  const document = {
    currentScript: { dataset: { refreshPath: '/refresh-session' } },
    body: { dataset: { displayMode: 'parchment' } },
    getElementById(id) { return regions[id] || null; },
    querySelector(value) {
      assert.equal(value, "meta[name='csrf-token']");
      return meta;
    },
    querySelectorAll(value) {
      if (value === selector) return selects.filter((select) => select.isConnected && select.matches(value));
      if (value === "input[name='authenticity_token']") return inputs;
      if (value === '[data-b270-theme-fallback]') return fallbacks;
      throw new Error(`Unsupported selector: ${value}`);
    },
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(callback);
    }
  };
  const formFor = (target) => ({
    querySelector(value) {
      assert.equal(value, selector);
      return target.matches(value) ? target : null;
    }
  });
  const form = formFor(select);
  const context = vm.createContext({
    document, window: {},
    fetch(url, options) {
      return new Promise((resolve, reject) => requests.push({ url, options, resolve, reject }));
    }
  });
  const emit = (type, target) => {
    const event = { type, target, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; } };
    event.done = Promise.all((listeners.get(type) || []).map((callback) => callback(event)));
    return event;
  };
  return {
    document, select, selects, form, formFor, region, headerRegion, meta, inputs, fallbacks, listeners, requests, emit,
    addSelect(dataset) {
      const other = new Select(dataset);
      other.value = other.dataset.b270SavedTheme;
      selects.push(other);
      return other;
    },
    evaluate: () => vm.runInContext(source, context, { filename, timeout: 1000 }),
    change: (target = select) => emit('change', target),
    async reply(index, response) {
      requests[index].resolve(response);
      await new Promise((resolve) => setImmediate(resolve));
    }
  };
}

function sessionResponse({ ok = true, token = 'fresh-token' } = {}) {
  return { ok, headers: { get(name) { assert.equal(name, 'X-CSRF-Token'); return token; } } };
}

function themeResponse({ ok = true, mode = 'earth' } = {}) {
  return { ok, json: async () => ({ display_mode: mode }) };
}

function assertIdle(select) {
  assert.equal(select.disabled, false);
  assert.equal(select.getAttribute('aria-busy'), null);
}

function assertFailed(h) {
  assert.equal(h.select.value, 'parchment');
  assert.equal(h.select.dataset.b270SavedTheme, 'parchment');
  assert.equal(h.document.body.dataset.displayMode, 'parchment');
  assert.equal(h.region.textContent, 'Couldn’t save the theme. Please select it again to retry.');
  assertIdle(h.select);
}

test('refreshes the session and CSRF tokens, PATCHes only the theme, and applies it only after success', async () => {
  const h = harness();
  h.evaluate();
  const change = h.change();
  assert.equal(h.select.disabled, true);
  assert.equal(h.select.getAttribute('aria-busy'), 'true');
  assert.equal(h.region.textContent, 'Saving theme…');
  assert.equal(h.document.body.dataset.displayMode, 'parchment');
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].url, '/refresh-session');
  // Normalize VM objects before comparing across realms.
  assert.deepEqual(JSON.parse(JSON.stringify(h.requests[0].options)), {
    credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'text/plain' }
  });

  await h.reply(0, sessionResponse());
  assert.equal(h.meta.content, 'fresh-token');
  assert.deepEqual(h.inputs.map((input) => input.value), ['fresh-token', 'fresh-token']);
  assert.equal(h.requests.length, 2);
  assert.equal(h.requests[1].url, h.select.dataset.b270ThemeUrl);
  assert.deepEqual(JSON.parse(JSON.stringify(h.requests[1].options)), {
    method: 'PATCH', credentials: 'same-origin', cache: 'no-store',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-CSRF-Token': 'fresh-token' },
    body: JSON.stringify({ display_mode: 'earth' })
  });
  assert.equal(h.document.body.dataset.displayMode, 'parchment');
  assert.equal(h.select.dataset.b270SavedTheme, 'parchment');
  assert.equal(h.select.disabled, true);

  await h.reply(1, themeResponse());
  await change.done;
  assert.equal(h.document.body.dataset.displayMode, 'earth');
  assert.equal(h.select.value, 'earth');
  assert.equal(h.select.dataset.b270SavedTheme, 'earth');
  assert.equal(h.region.textContent, 'Theme saved.');
  assertIdle(h.select);
});

for (const [name, response] of [
  ['HTTP failure', () => themeResponse({ ok: false })],
  ['mismatched saved theme', () => themeResponse({ mode: 'system' })],
  ['invalid JSON', () => ({ ok: true, json: async () => { throw new SyntaxError('Invalid JSON'); } })],
  ['network failure', null]
]) {
  test(`${name} restores the dropdown without applying the theme and allows retry`, async () => {
    const h = harness();
    h.evaluate();
    const change = h.change();
    await h.reply(0, sessionResponse());
    if (response) await h.reply(1, response());
    else h.requests[1].reject(new Error('Offline'));
    await change.done;
    assertFailed(h);

    h.select.value = 'earth';
    const retry = h.change();
    assert.equal(h.requests.length, 3);
    assert.equal(h.requests[2].url, '/refresh-session');
    await h.reply(2, sessionResponse({ token: 'retry-token' }));
    assert.equal(h.requests[3].options.headers['X-CSRF-Token'], 'retry-token');
    await h.reply(3, themeResponse());
    await retry.done;
    assert.equal(h.document.body.dataset.displayMode, 'earth');
    assert.equal(h.region.textContent, 'Theme saved.');
    assertIdle(h.select);
  });
}

for (const [name, response] of [
  ['unsuccessful session response', () => sessionResponse({ ok: false })],
  ['missing CSRF token', () => sessionResponse({ token: null })],
  ['session network failure', null]
]) {
  test(`${name} prevents PATCH and restores the dropdown`, async () => {
    const h = harness();
    h.evaluate();
    const change = h.change();
    if (response) await h.reply(0, response());
    else h.requests[0].reject(new Error('Offline'));
    await change.done;
    assert.equal(h.requests.length, 1);
    assert.equal(h.meta.content, 'old-token');
    assert.deepEqual(h.inputs.map((input) => input.value), ['old-token', 'old-token']);
    assertFailed(h);
  });
}

for (const [name, apply, expected] of [
  ['another reader', 'false', 'parchment'],
  ['the admin’s own reader', 'true', 'earth']
]) {
  test(`saving ${name} respects data-b270-theme-apply=${apply}`, async () => {
    const h = harness({ apply, url: '/admin/readers/7/theme' });
    h.evaluate();
    const change = h.change();
    await h.reply(0, sessionResponse());
    assert.equal(h.requests[1].url, '/admin/readers/7/theme');
    assert.equal(h.document.body.dataset.displayMode, 'parchment');
    await h.reply(1, themeResponse());
    await change.done;
    assert.equal(h.document.body.dataset.displayMode, expected);
    assert.equal(h.select.value, 'earth');
    assert.equal(h.select.dataset.b270SavedTheme, 'earth');
    assert.equal(h.region.textContent, 'Theme saved.');
    assertIdle(h.select);
  });
}

test('disabled select ignores duplicate changes and prevents form submission while saving', async () => {
  const h = harness();
  h.evaluate();
  assert.equal(h.emit('submit', h.form).defaultPrevented, false);
  const change = h.change();
  await h.change().done;
  assert.equal(h.requests.length, 1);
  assert.equal(h.emit('submit', h.form).defaultPrevented, true);
  assert.equal(h.region.textContent, 'Please wait for the theme to finish saving.');

  await h.reply(0, sessionResponse());
  await h.change().done;
  assert.equal(h.requests.length, 2);
  assert.equal(h.emit('submit', h.form).defaultPrevented, true);
  await h.reply(1, themeResponse());
  await change.done;
  assertIdle(h.select);
  assert.equal(h.emit('submit', h.form).defaultPrevented, false);
});

test('successful save for a disconnected select leaves the live DOM unchanged', async () => {
  const h = harness();
  h.evaluate();
  const change = h.change();
  await h.reply(0, sessionResponse());
  h.select.isConnected = false;
  h.document.body.dataset.displayMode = 'system';
  h.region.textContent = 'New page status';
  h.meta.content = 'new-page-token';
  h.inputs.forEach((input) => { input.value = 'new-page-token'; });
  await h.reply(1, themeResponse());
  await change.done;
  assert.equal(h.document.body.dataset.displayMode, 'system');
  assert.equal(h.region.textContent, 'New page status');
  assert.equal(h.meta.content, 'new-page-token');
  assert.deepEqual(h.inputs.map((input) => input.value), ['new-page-token', 'new-page-token']);
  assert.equal(h.select.dataset.b270SavedTheme, 'earth');
  assertIdle(h.select);
});

test('repeated script loads keep singleton listeners and hide fallbacks, including on Turbo load', async () => {
  const h = harness();
  h.evaluate();
  assert.equal(h.fallbacks[0].hidden, true);
  h.fallbacks.push({ hidden: false });
  h.evaluate();
  assert.ok(h.fallbacks.every((button) => button.hidden));
  h.fallbacks.push({ hidden: false });
  await h.emit('turbo:load', h.document).done;
  assert.ok(h.fallbacks.every((button) => button.hidden));
  h.evaluate();
  for (const type of ['change', 'submit', 'turbo:load']) {
    assert.equal(h.listeners.get(type).length, 1);
  }
  const change = h.change();
  await h.reply(0, sessionResponse());
  await h.reply(1, themeResponse());
  await change.done;
  assert.equal(h.requests.length, 2);
  assert.equal(h.document.body.dataset.displayMode, 'earth');
});

test('unmarked selects are ignored and their forms submit normally', async () => {
  const h = harness();
  delete h.select.dataset.b270ThemeUrl;
  h.evaluate();
  await h.change().done;
  assert.equal(h.requests.length, 0);
  assert.equal(h.select.value, 'earth');
  assert.equal(h.select.dataset.b270SavedTheme, 'parchment');
  assert.equal(h.document.body.dataset.displayMode, 'parchment');
  assert.equal(h.region.textContent, '');
  assertIdle(h.select);
  h.select.disabled = true;
  assert.equal(h.emit('submit', h.form).defaultPrevented, false);
});

function pairedHarness({ apply = 'true', url = '/profile/theme' } = {}) {
  const h = harness({ apply, url });
  h.select.value = h.select.dataset.b270SavedTheme = 'light';
  h.document.body.dataset.displayMode = 'light';
  // Added after initialization to exercise delegated events on Turbo-rendered controls.
  h.evaluate();
  h.header = h.addSelect({
    b270ThemeUrl: '/profile/theme', b270ThemeApply: 'true', b270SavedTheme: 'light',
    b270ThemeStatus: 'b270-header-theme-status'
  });
  return h;
}

function assertBusy(select) {
  assert.equal(select.disabled, true);
  assert.equal(select.getAttribute('aria-busy'), 'true');
}

for (const [name, url] of [
  ['Profile', '/profile/theme'],
  ['admin editing self', '/admin/readers/7/theme']
]) {
  for (const initiating of ['header', 'select']) {
    test(`${initiating} synchronizes with ${name}, saves first, and uses its own status region`, async () => {
      const h = pairedHarness({ url });
      const target = h[initiating];
      const peer = target === h.header ? h.select : h.header;
      const region = target === h.header ? h.headerRegion : h.region;
      const otherRegion = target === h.header ? h.region : h.headerRegion;
      otherRegion.textContent = 'Unrelated status';
      otherRegion.dataset.error = 'false';
      target.value = 'dark';
      const change = h.change(target);
      [target, peer].forEach(assertBusy);
      assert.equal(region.textContent, 'Saving theme…');
      assert.equal(otherRegion.textContent, 'Unrelated status');
      assert.equal(peer.value, 'light');
      assert.equal(h.document.body.dataset.displayMode, 'light');
      await h.reply(0, sessionResponse());
      assert.equal(h.requests[1].url, target.dataset.b270ThemeUrl);
      assert.deepEqual(JSON.parse(h.requests[1].options.body), { display_mode: 'dark' });
      assert.equal(h.document.body.dataset.displayMode, 'light');
      for (const select of [target, peer]) {
        assertBusy(select);
        assert.equal(select.dataset.b270SavedTheme, 'light');
      }
      await h.reply(1, themeResponse({ mode: 'dark' }));
      await change.done;
      for (const select of [target, peer]) {
        assert.equal(select.value, 'dark');
        assert.equal(select.dataset.b270SavedTheme, 'dark');
        assertIdle(select);
      }
      assert.equal(h.document.body.dataset.displayMode, 'dark');
      assert.equal(region.textContent, 'Theme saved.');
      assert.equal(otherRegion.textContent, 'Unrelated status');
    });
  }
}

for (const initiating of ['header', 'select']) {
  test(`${initiating} stays independent of another reader’s admin select during concurrent saves`, async () => {
    const h = pairedHarness({ apply: 'false', url: '/admin/readers/8/theme' });
    const first = h[initiating];
    const second = first === h.header ? h.select : h.header;
    first.value = 'dark';
    const firstChange = h.change(first);
    assertBusy(first);
    assertIdle(second);
    assert.equal(second.value, 'light');
    const firstRegion = first === h.header ? h.headerRegion : h.region;
    const secondRegion = first === h.header ? h.region : h.headerRegion;
    assert.equal(firstRegion.textContent, 'Saving theme…');
    assert.equal(secondRegion.textContent, '');
    assert.equal(h.emit('submit', h.formFor(second)).defaultPrevented, false);
    second.value = 'sepia';
    const secondChange = h.change(second);
    assert.equal(h.requests.length, 2);
    await h.reply(0, sessionResponse());
    await h.reply(1, sessionResponse());
    assert.equal(h.requests[2].url, first.dataset.b270ThemeUrl);
    assert.equal(h.requests[3].url, second.dataset.b270ThemeUrl);
    await h.reply(2, themeResponse({ mode: 'dark' }));
    await firstChange.done;
    assertIdle(first);
    assertBusy(second);
    assert.equal(second.value, 'sepia');
    assert.equal(second.dataset.b270SavedTheme, 'light');
    assert.equal(firstRegion.textContent, 'Theme saved.');
    assert.equal(secondRegion.textContent, 'Saving theme…');
    assert.equal(h.document.body.dataset.displayMode, first === h.header ? 'dark' : 'light');
    await h.reply(3, themeResponse({ mode: 'sepia' }));
    await secondChange.done;
    assertIdle(second);
    assert.equal(first.value, 'dark');
    assert.equal(first.dataset.b270SavedTheme, 'dark');
    assert.equal(second.value, 'sepia');
    assert.equal(second.dataset.b270SavedTheme, 'sepia');
    assert.equal(h.document.body.dataset.displayMode, h.header.value);
    assert.equal(secondRegion.textContent, 'Theme saved.');
  });
}

for (const url of ['/profile/theme', '/admin/readers/7/theme']) {
  for (const initiating of ['header', 'select']) {
    for (const phase of ['session', 'PATCH']) {
      test(`${initiating} ${phase} failure restores and unlocks the whole group for ${url}`, async () => {
        const h = pairedHarness({ url });
        const target = h[initiating];
        const peer = target === h.header ? h.select : h.header;
        const region = target === h.header ? h.headerRegion : h.region;
        const peerRegion = target === h.header ? h.region : h.headerRegion;
        // Each control retains its own rollback value, even if initially stale.
        peer.value = peer.dataset.b270SavedTheme = 'sepia';
        target.value = 'dark';
        const change = h.change(target);
        [target, peer].forEach(assertBusy);
        peer.value = 'dark';
        await h.change(peer).done;
        assert.equal(h.requests.length, 1);
        assert.equal(h.emit('submit', h.formFor(peer)).defaultPrevented, true);
        assert.equal(peerRegion.textContent, 'Please wait for the theme to finish saving.');
        assert.equal(region.textContent, 'Saving theme…');
        if (phase === 'PATCH') {
          await h.reply(0, sessionResponse());
          [target, peer].forEach(assertBusy);
          await h.change(peer).done;
          assert.equal(h.requests.length, 2);
          await h.reply(1, themeResponse({ ok: false }));
        } else {
          await h.reply(0, sessionResponse({ ok: false }));
        }
        await change.done;
        assert.equal(target.value, 'light');
        assert.equal(target.dataset.b270SavedTheme, 'light');
        assert.equal(peer.value, 'sepia');
        assert.equal(peer.dataset.b270SavedTheme, 'sepia');
        assert.equal(h.document.body.dataset.displayMode, 'light');
        assert.equal(region.textContent, 'Couldn’t save the theme. Please select it again to retry.');
        assert.equal(region.dataset.error, 'true');
        assert.equal(peerRegion.textContent, 'Please wait for the theme to finish saving.');
        assert.equal(peerRegion.dataset.error, 'false');
        [target, peer].forEach(assertIdle);
        assert.equal(h.emit('submit', h.formFor(peer)).defaultPrevented, false);

        const next = h.requests.length;
        peer.value = 'dark';
        const retry = h.change(peer);
        assert.equal(region.textContent, '');
        assert.equal(region.dataset.error, 'false');
        [target, peer].forEach(assertBusy);
        await h.reply(next, sessionResponse());
        await h.reply(next + 1, themeResponse({ mode: 'dark' }));
        await retry.done;
        for (const select of [target, peer]) {
          assert.equal(select.value, 'dark');
          assert.equal(select.dataset.b270SavedTheme, 'dark');
          assertIdle(select);
        }
        assert.equal(h.document.body.dataset.displayMode, 'dark');
        assert.equal(peerRegion.textContent, 'Theme saved.');
      });
    }
  }
}

test('header failure flags its status as an error, and retry saving and success clear the flag', async () => {
  const h = pairedHarness();
  h.region.textContent = 'Existing Profile status';
  h.header.value = 'dark';
  const change = h.change(h.header);
  assert.equal(h.headerRegion.dataset.error, 'false');
  await h.reply(0, sessionResponse());
  await h.reply(1, themeResponse({ ok: false }));
  await change.done;
  assert.equal(h.headerRegion.textContent, 'Couldn’t save the theme. Please select it again to retry.');
  assert.equal(h.headerRegion.dataset.error, 'true');

  h.header.value = 'dark';
  const retry = h.change(h.header);
  assert.equal(h.headerRegion.textContent, 'Saving theme…');
  assert.equal(h.headerRegion.dataset.error, 'false');
  await h.reply(2, sessionResponse());
  await h.reply(3, themeResponse({ mode: 'dark' }));
  await retry.done;
  assert.equal(h.headerRegion.textContent, 'Theme saved.');
  assert.equal(h.headerRegion.dataset.error, 'false');
  assert.equal(h.region.textContent, 'Existing Profile status');
  assert.equal(h.region.dataset.error, undefined);
});

for (const [name, options, grouped] of [
  ['Profile', {}, true],
  ['admin editing self', { url: '/admin/readers/7/theme' }, true],
  ['admin editing another reader', { url: '/admin/readers/8/theme', apply: 'false' }, false]
]) {
  test(`${name} retry clears a previous header error only when grouped`, async () => {
    const h = pairedHarness(options);
    h.header.value = 'dark';
    const change = h.change(h.header);
    await h.reply(0, sessionResponse());
    await h.reply(1, themeResponse({ ok: false }));
    await change.done;
    const error = 'Couldn’t save the theme. Please select it again to retry.';
    assert.equal(h.headerRegion.textContent, error);
    assert.equal(h.headerRegion.dataset.error, 'true');

    h.select.value = 'dark';
    const retry = h.change();
    assert.equal(h.region.textContent, 'Saving theme…');
    assert.equal(h.headerRegion.textContent, grouped ? '' : error);
    assert.equal(h.headerRegion.dataset.error, grouped ? 'false' : 'true');
    assert.equal(h.document.body.dataset.displayMode, 'light');
    await h.reply(2, sessionResponse());
    await h.reply(3, themeResponse({ mode: 'dark' }));
    await retry.done;
    assert.equal(h.region.textContent, 'Theme saved.');
    assert.equal(h.headerRegion.textContent, grouped ? '' : error);
    assert.equal(h.headerRegion.dataset.error, grouped ? 'false' : 'true');
    assert.equal(h.header.value, grouped ? 'dark' : 'light');
    assert.equal(h.document.body.dataset.displayMode, grouped ? 'dark' : 'light');
    [h.header, h.select].forEach(assertIdle);
  });
}

test('matching endpoints synchronize even without apply=true, but only the initiator controls body application', async () => {
  const h = pairedHarness({ apply: 'false' });
  h.select.value = 'dark';
  const change = h.change();
  [h.select, h.header].forEach(assertBusy);
  await h.reply(0, sessionResponse());
  await h.reply(1, themeResponse({ mode: 'dark' }));
  await change.done;
  for (const select of [h.select, h.header]) {
    assert.equal(select.value, 'dark');
    assert.equal(select.dataset.b270SavedTheme, 'dark');
    assertIdle(select);
  }
  assert.equal(h.document.body.dataset.displayMode, 'light');
});

test('disconnected controls and new Turbo page controls are not included in an in-flight group', async () => {
  const h = pairedHarness();
  const detached = h.addSelect({ ...h.header.dataset });
  detached.isConnected = false;
  h.header.value = 'dark';
  const change = h.change(h.header);
  assertIdle(detached);
  await h.reply(0, sessionResponse());
  h.header.isConnected = h.select.isConnected = false;
  const replacement = h.addSelect({ ...h.header.dataset });
  h.headerRegion.textContent = 'New page status';
  h.document.body.dataset.displayMode = 'sepia';
  await h.reply(1, themeResponse({ mode: 'dark' }));
  await change.done;
  for (const select of [detached, replacement]) {
    assert.equal(select.value, 'light');
    assert.equal(select.dataset.b270SavedTheme, 'light');
    assertIdle(select);
  }
  [h.header, h.select].forEach(assertIdle);
  assert.equal(h.headerRegion.textContent, 'New page status');
  assert.equal(h.document.body.dataset.displayMode, 'sepia');
});

test('a missing explicit status region does not write to the default region or prevent saving', async () => {
  const h = pairedHarness();
  h.header.dataset.b270ThemeStatus = 'missing-status';
  h.header.value = 'dark';
  const change = h.change(h.header);
  await h.reply(0, sessionResponse());
  await h.reply(1, themeResponse({ mode: 'dark' }));
  await change.done;
  assert.equal(h.region.textContent, '');
  assert.equal(h.headerRegion.textContent, '');
  assert.equal(h.document.body.dataset.displayMode, 'dark');
  [h.header, h.select].forEach(assertIdle);
});
