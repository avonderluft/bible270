const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

// Rendered-HTML fixtures mirror admin/_scripture_frames, admin/_scripture_text
// and admin/show. Only the real stylesheet supplies layout; no Rails or assets.
const hidden = (name, value) => `<input type="hidden" name="${name}" value="${value}">`;
const patch = hidden('_method', 'patch');
const scriptureRow = (source, disabled, reference, index) => {
  const custom = source === 'Custom';
  const id = `passage-${source}-${index}`;
  const toggle = disabled ? 'Enable' : 'Disable';
  const actions = custom
    ? `<div class="b270-scripture-actions"><a href="#edit">Edit</a>
        <form method="post" action="#toggle">${patch}${hidden('scripture_frame[enabled]', disabled ? '1' : '0')}<button class="b270-linkbtn" type="submit">${toggle}</button></form>
        <form method="post" action="#delete">${hidden('_method', 'delete')}<button class="b270-linkbtn" type="submit">Delete</button></form></div>`
    : `<form class="b270-scripture-default-toggle" method="post" action="#default">${patch}${hidden('enabled', disabled ? '1' : '0')}<button class="b270-linkbtn" type="submit">${toggle}</button></form>`;
  return `<article class="b270-scripture-library-entry b270-scripture-library-entry--${source.toLowerCase()}" data-source="${source.toLowerCase()}">
    <details class="b270-scripture-library-disclosure">
      <summary aria-describedby="${id}"><strong>${reference}</strong> · NKJV · ${source}${disabled ? ' · Disabled' : ''}</summary>
      <blockquote class="b270-scripture-library-text" id="${id}" role="tooltip" tabindex="0">A Scripture passage with enough text to wrap naturally inside the panel.\nA second line of passage text.</blockquote>
    </details>${actions}</article>`;
};
const library = `<section class="b270-panel" id="b270-scripture-frames" aria-labelledby="b270-scripture-frames-heading">
  <div class="b270-scripture-panel-header"><h2 class="b270-subhead" id="b270-scripture-frames-heading">Scripture frames</h2><a href="#add" class="b270-btn">Add text</a></div>
  ${['Custom', 'Default'].map((source) => `<div>
    ${scriptureRow(source, false, 'John 3:16', 0)}
    ${scriptureRow(source, true, 'A much longer Scripture reference, Psalm 119:105–112', 1)}</div>`).join('')}
</section>`;
const reader = (disabled) => `<div class="b270-panel">
  <h2 class="b270-subhead">Where they are in the plan</h2>
  <div class="b270-admin-position-controls">
    <form class="b270-startform" method="post" action="#start">${patch}${hidden('participation_id', '7')}
      <label class="b270-field"><span>Day:</span><input type="number" name="day" value="123" min="1" max="270"></label>
      <input type="submit" class="b270-btn" value="Move">
    </form>
    <form class="b270-startform" method="post" action="#start">${patch}${hidden('participation_id', '7')}
      <label class="b270-field"><span>Start date:</span><input type="date" name="start_date" value="2026-11-12"></label>
      <input type="submit" class="b270-btn" value="Set date">
    </form>
  </div>
  <p class="b270-hint">Moving someone re-maps the calendar only. Their check-offs are keyed to day numbers and are not touched.</p>
</div>
<div class="b270-panel b270-admin-control" id="b270-completion-animation">
  <h2 class="b270-subhead" id="b270-completion-animation-heading">Completion animation</h2>
  <form class="b270-admin-inline-form" method="post" action="#completion-animation" aria-labelledby="b270-completion-animation-heading">
    ${patch}${hidden('completion_dove_disabled', disabled ? '0' : '1')}<input type="submit" class="b270-btn" value="${disabled ? 'Enable' : 'Disable'}">
  </form>
</div>`;

test('admin rows, separate position forms and completion control fit (optional Chromium)', { timeout: 45000 }, (t) => {
  const probe = spawnSync('chromium', ['--version'], { timeout: 15000, encoding: 'utf8' });
  if (probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; optional admin layout checks skipped');
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  const screens = { library, 'reader-disable': reader(false), 'reader-enable': reader(true) };
  const widths = [240, 360, 390, 768, 1024, 1440];
  const browserCheck = function(styles, screens, widths) {
    const failures = [];
    let scenarios = 0;
    const check = (condition, message) => { if (!condition) failures.push(message); };
    const rect = (element) => element.getBoundingClientRect();
    const centerY = (element) => { const r = rect(element); return (r.top + r.bottom) / 2; };
    const bounds = (element) => {
      const r = rect(element);
      return `${element.tagName.toLowerCase()}${element.id ? '#' + element.id : ''}${element.className ? '.' + String(element.className).trim().replace(/\s+/g, '.') : ''} [left=${r.left.toFixed(1)}, right=${r.right.toFixed(1)}, top=${r.top.toFixed(1)}, bottom=${r.bottom.toFixed(1)}, width=${r.width.toFixed(1)}]`;
    };
    const beside = (left, right, name, centered = false) => {
      check(rect(left).right <= rect(right).left + 1, `${name}: overlap or reversed order: ${bounds(left)}; ${bounds(right)}`);
      const delta = centered ? Math.abs(centerY(left) - centerY(right)) : Math.abs(rect(left).top - rect(right).top);
      check(delta <= 1, `${name}: not on the same horizontal row (Y delta=${delta.toFixed(1)}): ${bounds(left)}; ${bounds(right)}`);
    };
    const inContent = (element, container, name) => {
      const r = rect(element);
      const c = rect(container);
      const css = container.ownerDocument.defaultView.getComputedStyle(container);
      const left = c.left + parseFloat(css.borderLeftWidth) + parseFloat(css.paddingLeft);
      const right = c.right - parseFloat(css.borderRightWidth) - parseFloat(css.paddingRight);
      check(r.left >= left - 1 && r.right <= right + 1, `${name}: outside content [left=${left.toFixed(1)}, right=${right.toFixed(1)}]: ${bounds(element)}`);
    };
    const noOverflow = (doc, name) => {
      const root = doc.documentElement;
      const offenders = [...doc.querySelectorAll('.b270-wrap *')].filter((element) => {
        const r = rect(element);
        return r.width > 0 && (r.right > root.clientWidth + 1 || r.left < -1);
      });
      check(root.scrollWidth <= root.clientWidth && offenders.length === 0,
        `${name}: horizontal page overflow (viewport=${root.clientWidth}px, scrollWidth=${root.scrollWidth}px); ${offenders.slice(0, 8).map(bounds).join('; ')}`);
    };
    for (const width of widths) {
      for (const [screen, markup] of Object.entries(screens)) {
        const viewport = document.createElement('iframe');
        viewport.style.cssText = `display:block;border:0;width:${width}px;height:900px`;
        document.body.append(viewport);
        const doc = viewport.contentDocument;
        doc.open();
        doc.write(`<!doctype html><html data-b270-display-mode="light"><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head><body class="b270" data-display-mode="light"><main class="b270-wrap">${markup}</main></body></html>`);
        doc.close();
        const name = `${screen}/${width}px`;
        const wrap = doc.querySelector('.b270-wrap');
        const maxWidth = parseFloat(viewport.contentWindow.getComputedStyle(wrap).maxWidth);
        // Classic Chromium scrollbars reduce available width on tall screens.
        const availableWidth = doc.documentElement.clientWidth;
        check(Number.isFinite(maxWidth) && Math.abs(rect(wrap).width - Math.min(availableWidth, maxWidth)) <= 1,
          `${name}: actual .b270-wrap must constrain the screen (max-width=${maxWidth}): ${bounds(wrap)}`);
        for (const panel of doc.querySelectorAll('.b270-panel')) inContent(panel, wrap, name);
        if (screen === 'library') {
          const panel = doc.querySelector('#b270-scripture-frames');
          check(panel.querySelectorAll('h3').length === 0, `${name}: no redundant group headings`);
          const heading = panel.querySelector('#b270-scripture-frames-heading');
          const add = panel.querySelector('a[href="#add"]');
          check(add.parentElement === heading.parentElement, `${name}: Add text belongs to the panel heading row`);
          beside(heading, add, `${name}/panel heading and Add text`, true);
          inContent(add, panel, `${name}/Add text`);
          const rows = [...doc.querySelectorAll('.b270-scripture-library-entry')];
          check(rows.length === 4, `${name}: both enabled/disabled custom and default fixtures exist`);
          for (const open of [false, true]) {
            for (const row of rows) {
              const label = `${name}/${row.dataset.source}/${open ? 'expanded' : 'collapsed'}/${row.querySelector('strong').textContent}`;
              const disclosure = row.firstElementChild;
              check(disclosure.matches('details.b270-scripture-library-disclosure'), `${label}: native details must be the first direct child`);
              disclosure.open = open;
              const summary = disclosure.querySelector(':scope > summary');
              const actions = disclosure.nextElementSibling;
              const custom = row.dataset.source === 'custom';
              check(actions.matches(custom ? '.b270-scripture-actions' : 'form.b270-scripture-default-toggle'), `${label}: actions are a direct sibling of details`);
              check(viewport.contentWindow.getComputedStyle(row).display === 'grid', `${label}: preserve the two-column grid`);
              beside(summary, actions, label);
              inContent(summary, row, label);
              inContent(actions, row, label);
              check(Math.abs(rect(actions).right - rect(row).right) <= 1, `${label}: actions must align to the row's right edge: ${bounds(actions)}; ${bounds(row)}`);
              if (custom) {
                check(viewport.contentWindow.getComputedStyle(actions).display === 'flex', `${label}: custom actions use flex`);
                const controls = [...actions.querySelectorAll('a,button')];
                check(controls.length === 3 && controls[0].textContent === 'Edit' && /^(Enable|Disable)$/.test(controls[1].textContent) && controls[2].textContent === 'Delete', `${label}: Edit, toggle and Delete are separate controls`);
                for (let i = 1; i < controls.length; i++) beside(controls[i - 1], controls[i], `${label}/actions`, true);
              } else {
                check(actions.querySelectorAll('button').length === 1, `${label}: default row has only its toggle`);
              }
              inContent(row, panel, label);
            }
            noOverflow(doc, `${name}/${open ? 'expanded' : 'collapsed'}`);
          }
        } else {
          const position = doc.querySelector('.b270-admin-position-controls');
          const forms = [...position.querySelectorAll(':scope > form.b270-startform')];
          check(forms.length === 2 && doc.querySelectorAll('form form').length === 0, `${name}: position actions must be two separate, non-nested forms`);
          check(forms[0].querySelector('input[type=number][name=day]') && !forms[0].querySelector('[name=start_date]') && forms[0].querySelector('[type=submit]').value === 'Move', `${name}: Move form contains only the day field`);
          check(forms[1].querySelector('input[type=date][name=start_date]') && !forms[1].querySelector('[name=day]') && forms[1].querySelector('[type=submit]').value === 'Set date', `${name}: Set date form contains only the date field`);
          if (width >= 768) beside(forms[0], forms[1], `${name}/position forms`, true);
          for (const form of forms) {
            const field = form.querySelector('label.b270-field');
            const label = field.querySelector('span');
            const input = field.querySelector('input');
            const submit = form.querySelector('[type=submit]');
            if (width > 480) {
              beside(label, input, `${name}/inline label`, true);
              beside(field, submit, `${name}/field and submit`, true);
            } else {
              for (const [before, after] of [[label, input], [field, submit]]) {
                const sameRow = rect(before).right <= rect(after).left + 1 && Math.abs(centerY(before) - centerY(after)) <= 1;
                check(sameRow || rect(after).top >= rect(before).bottom - 1, `${name}: narrow position controls may wrap but must not overlap: ${bounds(before)}; ${bounds(after)}`);
              }
            }
            inContent(form, position.closest('.b270-panel'), `${name}/position form`);
          }
          const completion = doc.querySelector('#b270-completion-animation.b270-panel.b270-admin-control');
          const heading = completion.querySelector(':scope > h2');
          const form = completion.querySelector(':scope > form.b270-admin-inline-form');
          const buttons = form.querySelectorAll('button,input[type=submit]');
          const enable = screen === 'reader-enable';
          check(form.querySelector('input[type=hidden][name=completion_dove_disabled]').value === (enable ? '0' : '1') && buttons.length === 1 && buttons[0].value === (enable ? 'Enable' : 'Disable'), `${name}: completion uses hidden state and exactly one explicit action`);
          const button = buttons[0];
          if (width >= 360) beside(heading, button, `${name}/completion heading and button`, true);
          inContent(form, completion, `${name}/completion form`);
          const css = viewport.contentWindow.getComputedStyle(completion);
          const contentRight = rect(completion).right - parseFloat(css.paddingRight) - parseFloat(css.borderRightWidth);
          check(Math.abs(rect(button).right - contentRight) <= 1, `${name}: completion button is right-aligned: ${bounds(button)}; panel content right=${contentRight.toFixed(1)}`);
          noOverflow(doc, name);
        }
        scenarios++;
        viewport.remove();
      }
    }
    const output = document.createElement('pre');
    output.id = 'result';
    output.textContent = JSON.stringify({ failures, scenarios });
    document.body.append(output);
  };
  // CSP also applies to the same-origin about:blank frames; all content is inline.
  const csp = `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src 'self' about:`;
  const page = `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${csp}"></head><body><script>(${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(screens)},${JSON.stringify(widths)})</script></body></html>`;
  const result = spawnSync('chromium', [
    '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    '--disable-background-networking', '--disable-component-update', '--no-first-run', '--no-default-browser-check',
    '--host-resolver-rules=MAP * ~NOTFOUND', '--dump-dom', '--timeout=5000', '--virtual-time-budget=1000',
    `data:text/html,${encodeURIComponent(page)}`
  ], { timeout: 20000, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024 });
  assert.equal(result.status, 0, result.stderr || String(result.error));
  const output = result.stdout.match(/<pre id="result">([^<]*)<\/pre>/);
  assert.ok(output, `Chromium completed all admin layout checks: ${result.stderr}`);
  const report = JSON.parse(output[1].replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
  assert.equal(report.scenarios, widths.length * Object.keys(screens).length);
  assert.equal(report.failures.length, 0, report.failures.join('\n'));
});
