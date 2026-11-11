import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createSocket } from 'node:dgram';
import { parseStartupOptions } from '../src/startup-options.js';

function bind(socket, port) {
  return new Promise((resolve, reject) => {
    socket.once('error', reject);
    socket.bind(port, '127.0.0.1', () => { socket.removeListener('error', reject); resolve(); });
  });
}

function close(socket) {
  try { socket.address(); } catch { return; }
  return new Promise(resolve => socket.close(resolve));
}

test('Normal launches keep port 5540; only an explicit valid App port overrides it', () => {
  assert.deepEqual(parseStartupOptions(['--app', '/tmp/fixture']), { appMode: true, port: 5540 });
  assert.deepEqual(parseStartupOptions(['/tmp/cli', '/tmp/config']), { appMode: false, port: 5540 });
  assert.deepEqual(parseStartupOptions(['--app', '/tmp/fixture', '--port', '15540']), { appMode: true, port: 15540 });
  for (const port of ['0', '-1', '65536', '1.5', 'NaN', ' 5540', '5540extra', '']) {
    assert.throws(() => parseStartupOptions(['--app', '/tmp/fixture', '--port', port]));
  }
  assert.throws(() => parseStartupOptions(['--app', '/tmp/fixture', '--port']));
  assert.throws(() => parseStartupOptions(['/tmp/cli', '/tmp/config', '--port', '15540']));
});

test('App mode uses an isolated port with 5540 occupied, exchanges JSON and exits with parent', { timeout: 15_000 }, async t => {
  const productionPort = createSocket('udp4');
  t.after(() => close(productionPort));
  try { await bind(productionPort, 5540); }
  catch (error) { if (error.code !== 'EADDRINUSE') throw error; } // Keep any existing bridge untouched.
  const reservation = createSocket('udp4');
  t.after(() => close(reservation));
  await bind(reservation, 0);
  const port = reservation.address().port;
  assert.notEqual(port, 5540);
  await close(reservation);
  const storage = await mkdtemp(join(tmpdir(), 'mijia-app-'));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.js', import.meta.url)), '--app', storage, '--port', String(port)],
    { stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-8192); });
  const exit = once(child, 'exit');
  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("No ready frame")); }, 7000);
      child.once("exit", () => clearTimeout(timeout));
      child.once('error', reject);
      child.once('exit', (code, signal) => reject(new Error(`Child exited before ready (code ${code}, signal ${signal})\n${stderr}`)));
      createInterface({ input: child.stdout }).on('line', line => {
        try {
          const frame = JSON.parse(line);
          if (frame.method === 'snapshot') {
            child.stdin.write(JSON.stringify({ id: frame.id, devices: [{ did: 'app-outlet', name: 'Outlet', kind: 'outlet', reachable: true, on: false }] }) + '\n');
          } else if (frame.event === 'ready') {
            assert.match(frame.code, /^\d{11}$/);
            assert.match(frame.uri, /^MT:/);
            assert.equal(frame.paired, false);
            clearTimeout(timeout);
            resolve();
          } else reject(new Error('Unexpected protocol frame'));
        } catch (error) { reject(error); }
      });
    });
    child.stdin.end();
    const [code] = await exit;
    assert.equal(code, 0);
  } finally {
    if (child.exitCode === null) { child.kill("SIGKILL"); await exit; }
    await rm(storage, { recursive: true, force: true });
  }
});
