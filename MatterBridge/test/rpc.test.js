import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DeviceRPC } from '../src/rpc.js';

test('RPC matches concurrent responses, propagates failure, and rejects after exit', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-rpc-'));
  const executable = join(dir, 'fake-mijia');
  await writeFile(executable, `#!/usr/bin/env node
const { createInterface } = require('node:readline');
createInterface({ input: process.stdin }).on('line', line => {
  const r = JSON.parse(line);
  if (r.method === 'exit') process.exit(0);
  if (r.method === 'hang') return;
  if (r.method === 'invalid') return console.log('bad-json');
  setTimeout(() => console.log(JSON.stringify({ id: r.id,
    ...(r.method === 'fail' ? { error: 'rejected' } : { devices: [r.method] })
  })), r.method === 'slow' ? 30 : 0);
});
`, { mode: 0o700 });
  let rpc;
  try {
    rpc = new DeviceRPC(executable, '/unused/devices.local.json');
    assert.deepEqual(await Promise.all([rpc.request('slow'), rpc.request('fast')]), [['slow'], ['fast']]);
    await assert.rejects(rpc.request('fail'), /operation failed/);
    await assert.rejects(rpc.request('exit'), /exited/);
    await assert.rejects(rpc.request('snapshot'), /closed/);
    rpc.close();
    rpc = new DeviceRPC(executable, '/unused/devices.local.json', { timeout: 200 });
    await assert.rejects(rpc.request('hang'), /timed out/);
    await assert.rejects(rpc.request('snapshot'), /closed/);
    rpc.close();
    rpc = new DeviceRPC(executable, '/unused/devices.local.json');
    await assert.rejects(rpc.request('invalid'), /Invalid device RPC output/);
  } finally {
    rpc?.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('missing Swift executable rejects pending request', async () => {
  const rpc = new DeviceRPC('/nonexistent/mijia-lan', '/unused/devices.local.json');
  try { await assert.rejects(rpc.request('snapshot'), /Cannot start/); }
  finally { rpc.close(); }
});
