import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Environment } from '@matter/main';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { WindowCoveringServer } from '@matter/main/behaviors/window-covering';
import { createBridge, validateDevices } from '../src/bridge.js';

const curtain = () => ({ did: 'covering', name: 'Curtain', kind: 'windowCovering', reachable: true,
  attributes: { position: 29, movement: 0 } });
const heater = () => ({ did: 'heat', name: 'Towel Rack', kind: 'thermostat', on: true, reachable: true,
  attributes: { temperature: 5900, targetTemperature: 6500, targetTemperatureMin: 4000, targetTemperatureMax: 6500, targetTemperatureStep: 500 } });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
async function until(condition) {
  const end = Date.now() + 3000;
  while (!condition()) { if (Date.now() > end) throw new Error('Expected worker completion'); await new Promise(setImmediate); }
}
async function fixture(devices, rpc) {
  const directory = await mkdtemp(join(tmpdir(), 'mijia-appliances-'));
  Environment.default.vars.set('storage.path', directory);
  try {
    const bridge = await createBridge(rpc, devices, { port: 15542, passcode: 20202021, discriminator: 3840 });
    return { bridge, async close() { await bridge.node.close(); await rm(directory, { recursive: true, force: true }); } };
  } catch (error) { await rm(directory, { recursive: true, force: true }); throw error; }
}

test('new standard endpoints construct from cache, retain unknown positions and synchronize without commands', async () => {
  let writes = 0;
  const d = curtain(), h = heater(), unknown = { ...curtain(), did: 'unknown', reachable: false, attributes: {} };
  const f = await fixture([d, h, unknown], { request() { writes++; throw new Error('Unexpected write'); } });
  try {
    assert.equal(f.bridge.endpoints.get(d.did).state.windowCovering.currentPositionLiftPercent100ths, 7100);
    assert.equal(f.bridge.endpoints.get(unknown.did).state.windowCovering.currentPositionLiftPercent100ths, null);
    assert.equal(f.bridge.endpoints.get(h.did).state.thermostat.occupiedHeatingSetpoint, 6500);
    d.attributes.position = 100;
    await f.bridge.sync([d, h, unknown]);
    assert.equal(f.bridge.endpoints.get(d.did).state.windowCovering.currentPositionLiftPercent100ths, 0);
    d.attributes.position = 0;
    await f.bridge.sync([d, h, unknown]);
    assert.equal(f.bridge.endpoints.get(d.did).state.windowCovering.currentPositionLiftPercent100ths, 10000);
    assert.equal(writes, 0);
    assert.throws(() => validateDevices([{ ...d, attributes: { position: -1, movement: 0 } }]));
  } finally { await f.close(); }
});

test('heating controls confirm real power and setpoint, reject unsupported steps/modes and roll back failures', async () => {
  const current = heater(), writes = [];
  let reject = false;
  const f = await fixture([current], { async request(method, params) {
    assert.equal(method, 'set'); writes.push(params);
    if (reject) throw new Error('Not confirmed');
    if (params.property === 'targetTemperature') current.attributes.targetTemperature = params.value;
    else current.on = params.on;
    return [structuredClone(current)];
  } });
  try {
    const endpoint = f.bridge.endpoints.get(current.did);
    await endpoint.set({ thermostat: { occupiedHeatingSetpoint: 6000 } });
    assert.equal(writes.length, 1);
    assert.deepEqual(writes[0], { did: current.did, property: 'targetTemperature', value: 6000 });
    await assert.rejects(endpoint.set({ thermostat: { occupiedHeatingSetpoint: 6100 } }));
    await assert.rejects(endpoint.set({ thermostat: { systemMode: 3 } }));
    assert.equal(writes.length, 1);
    await endpoint.set({ thermostat: { systemMode: 0 } });
    assert.equal(current.on, false);
    reject = true;
    await assert.rejects(endpoint.set({ thermostat: { occupiedHeatingSetpoint: 6500 } }));
    assert.equal(endpoint.state.thermostat.occupiedHeatingSetpoint, 6000);
    const before = writes.length;
    current.attributes.targetTemperature = 5500;
    await f.bridge.sync([current]);
    assert.equal(endpoint.state.thermostat.occupiedHeatingSetpoint, 5500);
    assert.equal(writes.length, before);
  } finally { await f.close(); }
});

test('appliance main power and secondary illumination remain independent endpoints', async () => {
  const current = [{ did: 'fireplace', name: 'Heating Power', kind: 'power', reachable: true, on: false },
    { did: 'fireplace:light:3', name: 'Flame Light', kind: 'light', reachable: true, on: true }];
  const writes = [];
  const f = await fixture(current, { async request(_method, params) {
    writes.push(params); current.find(d => d.did === params.did).on = params.on; return structuredClone(current);
  } });
  try {
    await f.bridge.endpoints.get('fireplace').act(agent => agent.get(OnOffServer).on());
    assert.deepEqual(writes, [{ did: 'fireplace', on: true }]);
    await f.bridge.endpoints.get('fireplace:light:3').act(agent => agent.get(OnOffServer).off());
    assert.equal(current[0].on, true);
    assert.equal(current[1].on, false);
  } finally { await f.close(); }
});

test('covering commands never invent current position and Stop bypasses an unfinished movement worker', async () => {
  const current = curtain(), writes = [], started = deferred(), movement = deferred();
  const f = await fixture([current], { async request(method, params) {
    assert.equal(method, 'set'); writes.push(params);
    if (params.property === 'position') {
      started.resolve();
      await movement.promise;
      return [{ ...current, attributes: { position: params.value, movement: 0 } }];
    }
    assert.equal(params.property, 'stop');
    current.attributes.position = 31;
    return [structuredClone(current)];
  } });
  try {
    const endpoint = f.bridge.endpoints.get(current.did);
    await endpoint.act(agent => agent.get(WindowCoveringServer).goToLiftPercentage({ liftPercent100thsValue: 6600 }));
    await started.promise;
    assert.equal(endpoint.state.windowCovering.currentPositionLiftPercent100ths, 7100);
    assert.deepEqual(writes, [{ did: current.did, property: 'position', value: 34 }]);
    await endpoint.act(agent => agent.get(WindowCoveringServer).stopMotion());
    await until(() => endpoint.state.windowCovering.currentPositionLiftPercent100ths === 6900);
    assert.equal(writes[1].property, 'stop');
    movement.resolve();
    await new Promise(setImmediate); // Drain promise continuations after the deliberately late old response.
    assert.equal(endpoint.state.windowCovering.currentPositionLiftPercent100ths, 6900);
    assert.equal(writes.length, 2);
    const before = writes.length;
    await f.bridge.sync([current]);
    assert.equal(writes.length, before);
    await assert.rejects(endpoint.set({ windowCovering: { mode: { motorDirectionReversed: true } } }));
  } finally { movement.resolve(); await f.close(); }
});

test('Open/Close use native actions; a failed movement never fabricates a position or retries the write', async () => {
  const current = curtain(), writes = [];
  let fail = false, failed = false;
  const f = await fixture([current], { async request(_method, params) {
    writes.push(params);
    if (fail) { failed = true; throw new Error('Unconfirmed native result'); }
    current.attributes.position = params.property === 'open' ? 100 : 0;
    return [structuredClone(current)];
  } });
  try {
    const endpoint = f.bridge.endpoints.get(current.did);
    await endpoint.act(agent => agent.get(WindowCoveringServer).upOrOpen());
    await until(() => endpoint.state.windowCovering.currentPositionLiftPercent100ths === 0);
    await endpoint.act(agent => agent.get(WindowCoveringServer).downOrClose());
    await until(() => endpoint.state.windowCovering.currentPositionLiftPercent100ths === 10000);
    assert.deepEqual(writes.map(w => [w.property, w.value]), [['open', true], ['close', true]]);
    fail = true;
    await endpoint.act(agent => agent.get(WindowCoveringServer).goToLiftPercentage({ liftPercent100thsValue: 5000 }));
    await until(() => failed);
    await new Promise(setImmediate);
    assert.equal(endpoint.state.windowCovering.currentPositionLiftPercent100ths, 10000);
    assert.equal(writes.length, 3);
    current.reachable = false;
    await f.bridge.sync([current]);
    await assert.rejects(endpoint.act(agent => agent.get(WindowCoveringServer).upOrOpen()));
    assert.equal(writes.length, 3);
  } finally { await f.close(); }
});
