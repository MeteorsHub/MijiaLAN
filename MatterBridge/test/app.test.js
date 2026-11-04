import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

test('App mode exchanges only JSON on stdout, reports pairing and exits with parent', { timeout: 15_000 }, async () => {
  const storage = await mkdtemp(join(tmpdir(), 'mijia-app-'));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.js', import.meta.url)), '--app', storage],
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
