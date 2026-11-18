const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { spawnSync } = require('node:child_process');
const { evaluateInChromium } = require('./helpers/chromium.cjs');

// Rendered-HTML fixtures mirror admin/_scripture_frames, admin/_scripture_text
// and admin/show. Only the real stylesheet supplies layout; no Rails or assets.
const hidden = (name, value) => `<input type="hidden" name="${name}" value="${value}">`;
const patch = hidden('_method', 'patch');
const scriptureRow = (source, disabled, reference, index) => {
  const custom = source === 'Custom';
  const id = `passage-${source}-${index}`;
  const toggle = disabled ? 'Enable' : 'Disable';
  const preview = `<button type="button" class="b270-linkbtn" aria-haspopup="dialog" aria-controls="b270-scripture-preview" aria-label="Preview ${reference}" data-b270-scripture-preview data-b270-preview-reference="${reference}" data-b270-preview-translation="NKJV" data-b270-preview-text="A Scripture passage.">Preview</button>`;
  const actions = `<div class="b270-scripture-actions">${preview}${custom
    ? `<a href="#edit">Edit</a>
        <form method="post" action="#toggle">${patch}${hidden('scripture_frame[enabled]', disabled ? '1' : '0')}<button class="b270-linkbtn" type="submit">${toggle}</button></form>
        <form method="post" action="#delete">${hidden('_method', 'delete')}<button class="b270-linkbtn" type="submit">Delete</button></form>`
    : `<form class="b270-scripture-default-toggle" method="post" action="#default">${patch}${hidden('enabled', disabled ? '1' : '0')}<button class="b270-linkbtn" type="submit">${toggle}</button></form>`}</div>`;
  return `<article class="b270-scripture-library-entry b270-scripture-library-entry--${source.toLowerCase()}" data-source="${source.toLowerCase()}">
    <details class="b270-scripture-library-disclosure">
      <summary aria-describedby="${id}"><strong>${reference}</strong> · NKJV · ${source}${disabled ? ' · Disabled' : ''}</summary>
      <blockquote class="b270-scripture-library-text" id="${id}" role="tooltip" tabindex="0">A Scripture passage with enough text to wrap naturally inside the panel.\nA second line of passage text.</blockquote>
    </details>${actions}</article>`;
};
const library = `<section class="b270-panel" id="b270-scripture-frames" aria-labelledby="b270-scripture-frames-heading">
  <details class="b270-index b270-scripture-frames" open>
  <summary class="b270-scripture-panel-header"><span class="b270-subhead" id="b270-scripture-frames-heading"><span class="b270-disclosure-show">Show Scripture frames</span><span class="b270-disclosure-hide">Hide Scripture frames</span></span><a href="#add" class="b270-btn">Add text</a></summary>
  ${['Custom', 'Default'].map((source) => `<div>
    ${scriptureRow(source, false, 'John 3:16', 0)}
    ${scriptureRow(source, true, 'A much longer Scripture reference, Psalm 119:105–112', 1)}</div>`).join('')}
</details></section>`;
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

// Mirror the rendered reader sections, including the shared completion summary
// and the candidate returned by progress-sync lookup. No disclosure JavaScript.
const readerSections = `<details class="b270-panel b270-admin-section" id="b270-progress-sync-panel">
  <summary id="b270-progress-sync-heading"><span class="b270-disclosure-show">Show Progress sync</span><span class="b270-disclosure-hide">Hide Progress sync</span></summary>
  <section class="b270-progress-sync b270-admin-section-content" id="b270-progress-sync" aria-labelledby="b270-progress-sync-heading">
    <p class="b270-hint">New check-offs sync one way to an account with the same email.</p>
    <form method="post" action="#lookup" class="b270-emailform">
      <label class="b270-field" for="b270-progress-sync-destination">Destination</label>
      <span class="b270-select-wrap b270-select-wrap--full"><select name="destination" id="b270-progress-sync-destination" class="b270-select"><option value="other">Other reading group</option></select></span>
      <input type="submit" class="b270-btn" value="Find account">
    </form>
    <div class="b270-progress-sync-candidate">
      <p><strong>Other Reader</strong> · reader@example.test</p>
      <p class="b270-hint">Confirm this account. Existing progress is copied only when requested.</p>
      <form method="post" action="#link" class="b270-emailform">${hidden('candidate', 'candidate-token')}${hidden('destination', 'other')}<input type="submit" class="b270-btn" value="Link account"></form>
    </div>
    <p class="b270-hint">No linked accounts.</p>
  </section>
</details>
<details class="b270-panel b270-admin-section" id="b270-reader-reflections">
  <summary><span class="b270-disclosure-show">Show Their reflections</span><span class="b270-disclosure-hide">Hide Their reflections</span></summary>
  <div class="b270-admin-section-content">
    <div class="b270-comment" id="comment-1"><div style="flex:1">
      <div class="b270-cmeta"><a href="#day-12">Day 12</a> · Nov 12, 2026 <a href="#edit" class="b270-cedit">edit</a></div>
      <div class="b270-cbody"><p>A reflection on <a href="#passage" data-b270-passage-link="true">John 3:16</a>.</p>
        ${scriptureRow('Custom', false, 'John 3:16', 'nested')}
      </div>
      <div class="b270-cactions"><form method="post" action="#like"><button class="b270-linkbtn" type="submit">Like</button></form><a href="#reply" class="b270-linkbtn">Reply</a></div>
      <div style="display:flex;gap:10px;margin-top:6px"><form method="post" action="#hide">${patch}<button class="b270-linkbtn" type="submit">Hide</button></form></div>
    </div></div>
  </div>
</details>
<details class="b270-panel b270-admin-section" id="b270-reader-completions">
  <summary><span class="b270-disclosure-label"><span class="b270-disclosure-show">Show Completions</span><span class="b270-disclosure-hide">Hide Completions</span></span><span class="b270-completions-summary">12/270 days · 4% · 3 days behind</span></summary>
  <div class="b270-admin-section-content">
    <form method="post" action="#through" class="b270-startform">${patch}${hidden('participation_id', '7')}
      <label class="b270-field"><span>Mark complete through day (0 clears everything)</span><input type="number" name="day" value="12" min="0" max="270"></label>
      <input type="submit" class="b270-btn" value="Apply">
    </form>
    <p class="b270-hint">This also clears anything after that day, so it sets their progress exactly.</p>
    <div class="b270-grid" style="margin-top:16px">${Array.from({ length: 270 }, (_, index) => `<form method="post" action="#day-${index + 1}" style="display:contents" id="day-${index + 1}">${hidden('participation_id', '7')}<button type="submit" class="b270-cell${index < 12 ? ' complete' : ''}">${index + 1}</button></form>`).join('')}</div>
    <p class="b270-hint">Click a day to toggle it complete.</p>
  </div>
</details>`;

// The nested passage fixture above is an intentional scope probe: section CSS
// must not turn descendant summaries into section headers or expose their text.
test('admin rows, separate position forms, completion control and reader disclosures fit (optional Chromium)', { timeout: 45000 }, async (t) => {
  const browser = process.env.CHROME_BIN || 'chromium';
  const probe = spawnSync(browser, ['--version'], { timeout: 15000, encoding: 'utf8' });
  if (!process.env.CHROME_BIN && probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; optional admin layout checks skipped');
  assert.ifError(probe.error);
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  const screens = { library, 'reader-disable': reader(false), 'reader-enable': reader(true), 'sections-light': readerSections, 'sections-dark': readerSections };
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
        const theme = screen === 'sections-dark' ? 'dark' : 'light';
                doc.write(`<!doctype html><html data-b270-display-mode="${theme}"><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head><body class="b270" data-display-mode="${theme}"><main class="b270-wrap">${markup}</main></body></html>`);
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
          inContent(heading, panel, `${name}/panel heading`);
          check(viewport.contentWindow.getComputedStyle(heading).minWidth === '0px', `${name}: heading can shrink around the fixed-width Add text button`);
          inContent(add, panel, `${name}/Add text`);
          const libraryToggle = panel.querySelector(':scope > details');
          check(heading.querySelector('.b270-disclosure-hide').getBoundingClientRect().width > 0, `${name}: expanded toggle says Hide`);
          libraryToggle.open = false;
          check(heading.querySelector('.b270-disclosure-show').getBoundingClientRect().width > 0, `${name}: collapsed toggle says Show`);
          check(panel.querySelector('.b270-scripture-library-entry').getBoundingClientRect().height === 0, `${name}: collapsed library hides entries`);
          libraryToggle.open = true;
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
              check(actions.matches('div.b270-scripture-actions'), `${label}: actions are a direct sibling of details`);
              const rowStyle = viewport.contentWindow.getComputedStyle(row);
              check(rowStyle.display === 'grid', `${label}: preserve the grid`);
              check(rowStyle.gridTemplateColumns.split(' ').length === (width <= 360 ? 1 : 2), `${label}: one column at <=360px, two columns otherwise`);
              if (width <= 360) {
                check(rect(disclosure).bottom <= rect(actions).top, `${label}: actions stack below the entire disclosure`);
                check(viewport.contentWindow.getComputedStyle(actions).justifySelf === 'end', `${label}: stacked actions justify to the end`);
              } else beside(summary, actions, label);
              inContent(summary, row, label);
              inContent(actions, row, label);
              check(Math.abs(rect(actions).right - rect(row).right) <= 1, `${label}: actions must align to the row's right edge: ${bounds(actions)}; ${bounds(row)}`);
              const actionStyle = viewport.contentWindow.getComputedStyle(actions);
              check(actionStyle.display === 'flex' && actionStyle.columnGap === '10px', `${label}: actions use inline flex with 10px gaps`);
              const controls = [...actions.querySelectorAll('a,button')];
              const preview = controls[0];
              check(preview.matches('button.b270-linkbtn[data-b270-scripture-preview]') && preview.type === 'button' && preview.textContent === 'Preview', `${label}: Preview is the first non-submit action`);
              check(preview.getAttribute('aria-haspopup') === 'dialog' && preview.getAttribute('aria-controls') === 'b270-scripture-preview', `${label}: Preview identifies its dialog`);
              if (custom) {
                check(controls.length === 4 && controls[1].textContent === 'Edit' && /^(Enable|Disable)$/.test(controls[2].textContent) && controls[3].textContent === 'Delete', `${label}: Preview, Edit, toggle and Delete are separate controls`);
              } else {
                check(controls.length === 2 && controls[1].closest('form.b270-scripture-default-toggle'), `${label}: default row has Preview and its toggle form`);
              }
              for (let i = 1; i < controls.length; i++) beside(controls[i - 1], controls[i], `${label}/actions`, true);
              inContent(row, panel, label);
            }
            noOverflow(doc, `${name}/${open ? 'expanded' : 'collapsed'}`);
          }
        } else if (screen.startsWith('sections-')) {
          const css = (element) => viewport.contentWindow.getComputedStyle(element);
          const visible = (element) => rect(element).width > 0 && rect(element).height > 0 && css(element).visibility === 'visible';
          const sections = [...doc.querySelectorAll('details.b270-admin-section')];
          const completion = doc.querySelector('#b270-reader-completions');
          const stats = completion.querySelector(':scope > summary > .b270-completions-summary');
          const label = completion.querySelector(':scope > summary > .b270-disclosure-label');
          const checkStats = (state) => {
            check(visible(stats) && stats.textContent === '12/270 days · 4% · 3 days behind', `${name}/${state}: completion summary remains visible and accurate`);
            const style = css(stats);
            const muted = css(doc.body).getPropertyValue('--muted').trim();
            const probe = doc.createElement('span');
            probe.style.color = muted;
            doc.body.append(probe);
            check(style.fontSize === '12.5px' && style.fontWeight === '400' && style.fontFamily.includes('system-ui') && style.color === css(probe).color, `${name}/${state}: completion summary uses small muted system text in ${theme} theme`);
            probe.remove();
            inContent(stats, completion, `${name}/${state}/completion summary`);
            inContent(label, completion, `${name}/${state}/completion label`);
            if (width >= 768) beside(label, stats, `${name}/${state}/completion toggle and summary`, true);
            if (width === 240) check(rect(stats).top >= rect(label).bottom - 1, `${name}/${state}: narrow completion summary wraps below the toggle`);
          };
          const checkPanels = (state) => {
            for (const panel of sections) {
              check(panel.scrollWidth <= panel.clientWidth + 1, `${name}/${state}: ${panel.id} has no horizontal panel overflow`);
              inContent(panel.querySelector(':scope > summary'), panel, `${name}/${state}/section summary`);
            }
            checkStats(state);
            noOverflow(doc, `${name}/${state}`);
          };
          check(sections.length === 3, `${name}: all three reader sections exist`);
          check(completion.querySelectorAll('.b270-grid button').length === 270, `${name}: full completion grid exercises layout`);
          const titles = ['Progress sync', 'Their reflections', 'Completions'];
          for (const [index, section] of sections.entries()) {
            const summary = section.querySelector(':scope > summary');
            const content = section.querySelector(':scope > .b270-admin-section-content');
            const show = summary.querySelector('.b270-disclosure-show');
            const hide = summary.querySelector('.b270-disclosure-hide');
            const contents = [...content.querySelectorAll('p,form,input:not([type=hidden]),select,button,a,.b270-grid,.b270-comment,.b270-progress-sync-candidate')];
            const checkState = (open, state) => {
              check(section.open === open, `${name}/${section.id}/${state}: native details state`);
              check(show.textContent === `Show ${titles[index]}` && hide.textContent === `Hide ${titles[index]}`, `${name}/${section.id}/${state}: accurate Show/Hide labels`);
              check(visible(show) === !open && visible(hide) === open, `${name}/${section.id}/${state}: only the correct label is visible`);
              check(visible(content) === open, `${name}/${section.id}/${state}: actual section content visibility`);
              if (!open) check(css(content).display === 'none' && contents.every((element) => !visible(element)), `${name}/${section.id}/${state}: forms, grid, comments and candidate are really hidden`);
              checkPanels(`${section.id}/${state}`);
            };
            check(!section.hasAttribute('open'), `${name}/${section.id}: closed by default`);
            checkState(false, 'default');
            summary.click();
            checkState(true, 'clicked-open');
            for (const element of contents) {
              // Nested passage text has its own native disclosure state.
              if (!element.closest('.b270-scripture-library-disclosure')) check(visible(element) || css(element).display === 'contents', `${name}/${section.id}: expanded content visible: ${bounds(element)}`);
            }
            if (section.id === 'b270-reader-reflections') {
              const passage = section.querySelector('details.b270-scripture-library-disclosure');
              const passageSummary = passage.querySelector(':scope > summary');
              const passageText = passage.querySelector('blockquote');
              check(!passage.open && visible(passageSummary) && css(passageSummary).display !== 'flex', `${name}: nested passage summary is not restyled as an admin section`);
              check(!visible(passageText), `${name}: opening reflections does not expose closed passage text`);
              passageSummary.click();
              check(passage.open && visible(passageText) && visible(hide) && !visible(show), `${name}: nested passage opens independently without changing parent labels`);
              checkPanels('nested-passage-open');
              passageSummary.click();
              check(!passage.open && !visible(passageText), `${name}: nested passage closes independently`);
              for (const control of section.querySelectorAll('.b270-cedit,.b270-cactions a,.b270-cactions button,.b270-cbody > p a,form[action="#hide"] button')) {
                check(visible(control), `${name}: reflection and passage controls are unaffected: ${control.textContent}`);
              }
            }
            summary.click();
            checkState(false, 'clicked-closed');
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
    return { failures, scenarios };
  };
  // CDP avoids command-line size limits with the full rendered 270-day grid.
  const expression = `(${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(screens)},${JSON.stringify(widths)})`;
  const report = await evaluateInChromium(browser, expression);
  assert.equal(report.scenarios, widths.length * Object.keys(screens).length);
  assert.equal(report.failures.length, 0, report.failures.join('\n'));
});

test('progress-sync fragment navigation reveals the closed section and candidate (optional Chromium)', { timeout: 45000 }, async (t) => {
  const browser = process.env.CHROME_BIN || 'chromium';
  const probe = spawnSync(browser, ['--version'], { timeout: 15000, encoding: 'utf8' });
  if (!process.env.CHROME_BIN && probe.error?.code === 'ENOENT') return t.skip('Chromium is not installed; optional fragment navigation check skipped');
  assert.ifError(probe.error);
  assert.equal(probe.status, 0, probe.stderr || String(probe.error));
  const styles = readFileSync(resolve(__dirname, '../../app/views/bible270/shared/_styles.html.erb'), 'utf8');
  const browserCheck = async function(styles, markup) {
    const failures = [];
    const check = (condition, message) => { if (!condition) failures.push(message); };
    const viewport = document.createElement('iframe');
    viewport.style.cssText = 'display:block;border:0;width:390px;height:900px';
    const loaded = new Promise((resolve) => { viewport.onload = resolve; });
    viewport.srcdoc = `<!doctype html><html data-b270-display-mode="light"><head>${styles}</head><body class="b270" data-display-mode="light"><main class="b270-wrap">${markup}</main></body></html>`;
    document.body.append(viewport);
    await loaded;
    const doc = viewport.contentDocument;
    const view = viewport.contentWindow;
    const panel = doc.querySelector('#b270-progress-sync-panel');
    const target = doc.querySelector('#b270-progress-sync');
    const candidate = target.querySelector('.b270-progress-sync-candidate');
    const confirm = candidate.querySelector('input[type=submit]');
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && view.getComputedStyle(element).visibility === 'visible';
    };
    check(target.matches('section.b270-progress-sync.b270-admin-section-content') && target.parentElement === panel, 'redirect target remains the inner section, not the details wrapper');
    check(!panel.open && !visible(target) && !visible(candidate) && !visible(confirm), 'progress sync and candidate confirmation start closed and hidden');
    check(view.location.hash === '', 'fixture has no fragment before navigation');

    // A real same-document navigation invokes Chromium's native ancestor-details
    // reveal algorithm. No open assignment, synthetic event, or keypress stand-in.
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Progress-sync fragment navigation did not emit hashchange')), 3000);
      view.addEventListener('hashchange', () => { clearTimeout(timeout); resolve(); }, { once: true });
      view.location.hash = '#b270-progress-sync';
    });
    await new Promise((resolve) => requestAnimationFrame(resolve));
    check(view.location.hash === '#b270-progress-sync' && target.matches(':target'), 'actual fragment navigation reaches the preserved redirect hash');
    check(panel.open, 'fragment navigation opens the closed native parent details');
    check(visible(target) && visible(candidate) && visible(confirm) && confirm.value === 'Link account', 'fragment navigation reveals the candidate and Link account confirmation');
    const summary = panel.querySelector(':scope > summary');
    check(visible(summary.querySelector('.b270-disclosure-hide')) && !visible(summary.querySelector('.b270-disclosure-show')), 'fragment-revealed summary says Hide Progress sync');
    check(!doc.querySelector('#b270-reader-reflections').open && !doc.querySelector('#b270-reader-completions').open, 'fragment navigation leaves unrelated reader sections closed');
    summary.click();
    check(!panel.open && !visible(candidate) && !visible(confirm), 'native summary can close the fragment-revealed section again');
    viewport.remove();
    return { failures };
  };
  const expression = `(${browserCheck.toString()})(${JSON.stringify(styles)},${JSON.stringify(readerSections)})`;
  // Keep the helper's default focus emulation enabled for native fragment reveal.
  const report = await evaluateInChromium(browser, expression);
  assert.deepEqual(report.failures, [], report.failures.join('\n'));
});
