const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const enabled = process.env.B270_WEBKIT_TESTS === '1';
const stripERB = (name) => readFileSync(resolve(__dirname, `../../app/views/bible270/shared/${name}.html.erb`), 'utf8').replace(/<%[\s\S]*?%>/g, '');

async function renderedPixels(page) {
  const png = await page.screenshot({ animations: 'allow', scale: 'css' });
  return page.evaluate(async (png) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width;
    canvas.height = image.height;
    const drawing = canvas.getContext('2d');
    drawing.drawImage(image, 0, 0);
    const pixels = drawing.getImageData(0, 0, canvas.width, canvas.height).data;
    const width = Math.min(image.width, document.documentElement.clientWidth);
    const height = Math.min(image.height, document.documentElement.clientHeight);
    let bright = 0;
    let white = 0;
    for (let y = 2; y < height - 2; y++) {
      for (let x = 2; x < width - 2; x++) {
        const i = (y * image.width + x) * 4;
        const minimum = Math.min(pixels[i], pixels[i + 1], pixels[i + 2]);
        if (minimum > 200) bright++;
        if (minimum > 245) white++;
      }
    }
    return { bright, white, total: (width - 4) * (height - 4) };
  }, png.toString('base64'));
}

test('WebKit renders the real completion dove on mobile and desktop', {
  skip: enabled ? false : 'Set B270_WEBKIT_TESTS=1 with Playwright/WebKit installed', timeout: 90000
}, async (t) => {
  const { webkit, devices } = require('playwright');
  const browser = await webkit.launch();
  const styles = stripERB('_styles');
  const figure = stripERB('_scripture_frame');
  const dove = stripERB('_day_completion_dove');
  const cases = [
    { name: 'iPhone portrait, Papyrus', options: devices['iPhone 13'], theme: 'light' },
    { name: 'iPhone landscape, Cedar, long passage', options: devices['iPhone 13 landscape'], theme: 'dark', long: true },
    { name: 'desktop, Forest', options: { viewport: { width: 1280, height: 800 } }, theme: 'dark_green' },
    { name: 'iPhone reduced motion', options: { ...devices['iPhone 13'], reducedMotion: 'reduce' }, theme: 'light', reduced: true }
  ];
  try {
    for (const scenario of cases) {
      await t.test(scenario.name, async () => {
        const context = await browser.newContext(scenario.options);
        try {
          const page = await context.newPage();
          const errors = [];
          page.on('pageerror', (error) => errors.push(error.message));
          await page.route('**/*', (route) => route.abort());
          await page.setContent(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head>
            <body class="b270" data-display-mode="${scenario.theme}"><main style="height:2000px">Reading plan</main>
            <div class="b270-completion is-visible" data-b270-completion>
              <div class="b270-completion-frame" data-b270-completion-frame>${figure}</div>${dove}
            </div></body></html>`);
          await page.evaluate((long) => {
            document.querySelector('[data-b270-scripture-art]').hidden = false;
            document.querySelector('[data-b270-scripture-reference]').textContent = 'Psalm 119:130';
            document.querySelector('[data-b270-scripture-translation]').textContent = 'NASB95';
            document.querySelector('[data-b270-scripture-text]').textContent = ('The unfolding of Your words gives light;\nIt gives understanding to the simple.\n').repeat(long ? 100 : 1);
            document.querySelector('[data-b270-completion-frame]').getAnimations().forEach((animation) => animation.finish());
            window.scrollTo(0, 600);
            const root = document.querySelector('[data-b270-completion]');
            root.classList.add('is-flying');
            root.querySelector('[data-b270-completion-dove]').classList.add('b270-completion-dove-active');
            document.getAnimations().forEach((animation) => animation.pause());
          }, !!scenario.long);
          assert.ok(await page.evaluate(() => window.scrollY > 0), 'the page really scrolled');
          if (scenario.long) {
            const scroll = await page.locator('[data-b270-completion-frame]').evaluate((frame) => {
              frame.scrollTop = 50;
              return { position: frame.scrollTop, overflow: frame.scrollHeight > frame.clientHeight,
                bounded: frame.getBoundingClientRect().height <= innerHeight - 24 };
            });
            assert.deepEqual(scroll, { position: 50, overflow: true, bounded: true });
          }
          const sample = (time) => page.evaluate((time) => {
            document.getAnimations().forEach((animation) => { animation.pause(); animation.currentTime = time; });
            const root = document.querySelector('[data-b270-completion]');
            const dove = root.querySelector('[data-b270-completion-dove]');
            const svg = dove.querySelector('svg');
            const flight = dove.getAnimations().find((animation) => animation.animationName === 'b270-dove-flight');
            const exit = root.getAnimations().find((animation) => animation.animationName === 'b270-completion-exit');
            const rect = dove.getBoundingClientRect();
            const viewport = root.getBoundingClientRect();
            const matrix = new DOMMatrix(getComputedStyle(dove).transform);
            const inverse = svg.getScreenCTM().inverse();
            const paths = [...svg.querySelectorAll('.b270-dove-silhouette path')];
            const covered = [0, .25, .5, .75, 1].every((x) => [0, .25, .5, .75, 1].every((y) => {
              const point = new DOMPoint(viewport.left + x * viewport.width, viewport.top + y * viewport.height).matrixTransform(inverse);
              return paths.some((path) => path.isPointInFill(point));
            }));
            return {
              tag: dove.tagName, position: getComputedStyle(dove).position, svgFilter: getComputedStyle(svg).filter,
              filter: getComputedStyle(dove).filter, willChange: getComputedStyle(dove).willChange,
              display: getComputedStyle(dove).display, visibility: getComputedStyle(root).visibility,
              opacity: Number(getComputedStyle(root).opacity), fill: getComputedStyle(svg.querySelector('g')).fill,
              width: rect.width, x: rect.x + rect.width / 2, y: rect.y + rect.height / 2,
              centerX: viewport.x + viewport.width / 2, centerY: viewport.y + viewport.height / 2,
              scale: Math.hypot(matrix.a, matrix.b), svgWidth: svg.getBBox().width,
              flight: flight?.effect.getComputedTiming().duration, exit: exit?.effect.getComputedTiming().endTime,
              fadeDuration: exit?.effect.getComputedTiming().duration, fadeDelay: exit?.effect.getComputedTiming().delay,
              covered, clipped: getComputedStyle(root).overflow === 'hidden',
              layoutAnimation: flight?.effect.getKeyframes().some((frame) => 'top' in frame || 'left' in frame)
            };
          }, time);
          if (scenario.reduced) {
            assert.equal((await sample(0)).display, 'none');
          } else {
            let previous = await sample(112);
            assert.equal(previous.tag, 'DIV');
            assert.equal(previous.position, 'absolute');
            assert.equal(previous.filter, 'none');
            assert.equal(previous.svgFilter, 'none');
            assert.equal(previous.willChange, 'auto');
            assert.equal(previous.layoutAnimation, false);
            assert.equal(previous.flight, 1000);
            assert.equal(previous.exit, 1000);
            assert.equal(previous.fadeDuration, 200);
            assert.ok(Math.abs(previous.fadeDelay - 800) < 0.01);
            assert.match(previous.fill, /b270-dove-light/);
            assert.ok(previous.svgWidth > 200, 'the complete SVG silhouette has nonzero geometry');
            for (const time of [250, 600, 850, 999]) {
              const current = await sample(time);
              assert.ok(current.width > previous.width && current.scale > previous.scale, `dove grows at ${time}ms`);
              assert.ok(current.y < previous.y, `dove moves toward the center at ${time}ms`);
              assert.ok(Math.abs(current.x - current.centerX) < 1, `dove remains centered after scrolling at ${time}ms: ${JSON.stringify(current)}`);
              if (time <= 800) assert.equal(current.opacity, 1);
              else assert.ok(current.opacity > 0 && current.opacity < previous.opacity, 'shared fade has no frozen endpoint');
              previous = current;
            }
            const beforeFade = await sample(800);
            assert.ok(!beforeFade.covered && beforeFade.clipped, 'the dove stays recognizable without a screen-filling white flash');
            assert.equal(beforeFade.opacity, 1);
            const finishPixels = await renderedPixels(page);
            assert.ok(finishPixels.white / finishPixels.total < .6, `the finish does not wash the viewport white: ${JSON.stringify(finishPixels)}`);
            await sample(600);
            const painted = await page.screenshot({ animations: 'allow', scale: 'css' });
            await page.locator('[data-b270-completion-dove] > svg').evaluate((svg) => { svg.style.visibility = 'hidden'; });
            const withoutBird = await page.screenshot({ animations: 'allow', scale: 'css' });
            assert.ok(!painted.equals(withoutBird), 'the SVG itself paints, not just its halo');
            await page.locator('[data-b270-completion-dove] > svg').evaluate((svg) => { svg.style.removeProperty('visibility'); });
            if (scenario.options.isMobile) {
              await page.setViewportSize({ width: 390, height: 500 });
              const midFlight = await sample(500);
              assert.ok(midFlight.y > midFlight.centerY && midFlight.y < midFlight.centerY + 110,
                'mid-flight rise uses the resized mobile viewport');
              assert.ok(Math.abs(midFlight.x - midFlight.centerX) < 1);
              const resized = await sample(999);
              assert.ok(Math.abs(resized.y - resized.centerY) < 1 && Math.abs(resized.x - resized.centerX) < 1,
                `flight finishes centered in the resized viewport: ${JSON.stringify(resized)}`);
            }
            const end = await sample(1000);
            assert.ok(Math.abs(end.scale - 1.15) < 0.001, 'the dove keeps growing through the fade');
            assert.ok(!end.covered, 'the final fade does not become a white flash');
            assert.equal(end.opacity, 0);
            assert.equal(end.visibility, 'hidden');
          }
          assert.deepEqual(errors, []);
        } finally { await context.close(); }
      });
    }
    await t.test('free-running iPhone flight paints a growing bird and cleans up on animationend', async () => {
      const context = await browser.newContext(devices['iPhone 13']);
      try {
        const page = await context.newPage();
        await page.route('**/*', (route) => route.abort());
        await page.setContent(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">${styles}</head>
          <body class="b270" data-display-mode="dark"><div class="b270-completion" data-b270-completion data-b270-completion-event="webkit-live" hidden>
          <div class="b270-completion-frame" data-b270-completion-frame>${figure}</div>${dove}</div></body></html>`);
        await page.evaluate(() => {
          document.addEventListener('animationstart', (event) => {
            if (event.animationName === 'b270-dove-flight') window.flightStarted = performance.now();
          });
        });
        const ui = stripERB('_day_completion_ui').match(/<script\b[^>]*>([\s\S]*?)<\/script>/i)[1];
        await page.addScriptTag({ content: ui });
        const brightPixels = async () => (await renderedPixels(page)).bright;
        await page.waitForFunction(() => getComputedStyle(document.querySelector('[data-b270-completion-frame]')).opacity === '1');
        const background = await brightPixels();
        await page.waitForFunction(() => typeof window.flightStarted === 'number');
        const footprints = [];
        for (const time of [150, 300, 500]) {
          await page.waitForFunction((time) => performance.now() - window.flightStarted >= time, time);
          footprints.push(await brightPixels() - background);
        }
        assert.ok(footprints[0] > 20, `a visible bird appears early in flight: ${footprints}`);
        assert.ok(footprints[1] > footprints[0] * 1.3 && footprints[2] > footprints[1] * 1.3,
          `painted pixels grow with the bird instead of staying tiny or flashing: ${footprints}`);
        await page.waitForSelector('[data-b270-completion]', { state: 'detached', timeout: 4000 });
      } finally { await context.close(); }
    });
  } finally { await browser.close(); }
});
