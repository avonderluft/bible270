const { spawn } = require('node:child_process');
const { mkdtemp, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

async function evaluateInChromium(browser, expression, { timeout = 20000, focus = true } = {}) {
  const profile = await mkdtemp(join(tmpdir(), 'b270-chromium-'));
  const pending = new Map();
  let child, deadline, exitPromise, exited = false, closing = false;
  let nextId = 0, buffer = '', stderr = '', disconnected;

  function fail(error) {
    if (closing || disconnected) return;
    disconnected = error;
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  }

  function send(method, params = {}, sessionId) {
    if (disconnected) return Promise.reject(disconnected);
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject, method });
      try {
        child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
      } catch (error) {
        fail(error);
      }
    });
  }

  try {
    try {
      child = spawn(browser, [
        '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
        '--no-first-run', '--no-default-browser-check', '--remote-debugging-pipe',
        `--user-data-dir=${profile}`
      ], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });

      exitPromise = new Promise((resolve) => {
        child.once('error', (error) => {
          exited = true;
          resolve();
          fail(new Error(`Could not start ${browser}: ${error.message}`));
        });
        child.once('exit', (code, signal) => {
          exited = true;
          resolve();
          fail(new Error(`Chromium exited (code ${code}, signal ${signal})`));
        });
      });
      child.stderr.setEncoding('utf8');
      child.stderr.on('data', (chunk) => { stderr = (stderr + chunk).slice(-8192); });
      child.stderr.on('error', (error) => fail(error));
      child.stdio[3].on('error', (error) => fail(new Error(`Chromium CDP write failed: ${error.message}`)));
      child.stdio[4].on('error', (error) => fail(new Error(`Chromium CDP read failed: ${error.message}`)));
      child.stdio[4].on('end', () => fail(new Error('Chromium disconnected from CDP')));
      child.stdio[4].setEncoding('utf8');
      child.stdio[4].on('data', (chunk) => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\0')) !== -1) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 1);
          let response;
          try {
            response = JSON.parse(frame);
          } catch (error) {
            fail(new Error(`Invalid Chromium CDP message: ${error.message}`));
            return;
          }
          const request = pending.get(response.id);
          if (!request) continue;
          pending.delete(response.id);
          if (response.error) {
            request.reject(new Error(`Chromium CDP ${request.method}: ${JSON.stringify(response.error)}`));
          } else {
            request.resolve(response.result);
          }
        }
      });
      deadline = setTimeout(() => fail(new Error(`Chromium evaluation timed out after ${timeout}ms`)), timeout);

      const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
      await send('Emulation.setFocusEmulationEnabled', { enabled: focus }, sessionId);
      const evaluation = await send('Runtime.evaluate', {
        expression, returnByValue: true, awaitPromise: true
      }, sessionId);
      if (evaluation.exceptionDetails) {
        const details = evaluation.exceptionDetails;
        throw new Error(`Chromium evaluation exception: ${details.exception?.description || details.text}`);
      }
      return evaluation.result.value;
    } finally {
      closing = true;
      clearTimeout(deadline);
      if (child && !exited) {
        // Ask the browser to close its renderers too, even if evaluation is stuck.
        try {
          child.stdio[3].write(JSON.stringify({ id: ++nextId, method: 'Browser.close' }) + '\0');
        } catch {}
        const kill = setTimeout(() => child.kill('SIGKILL'), 1000);
        try {
          await exitPromise;
        } finally {
          clearTimeout(kill);
        }
      }
      await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
    }
  } catch (error) {
    throw new Error(`${error.message}${stderr ? `\nChromium stderr (last 8192 characters):\n${stderr}` : ''}`, { cause: error });
  }
}

module.exports = { evaluateInChromium };
