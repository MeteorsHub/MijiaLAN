import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Environment, Logger } from '@matter/main';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { createBridge, identity, validateDevices } from '../src/bridge.js';

Logger.defaultLogLevel = 'error';
const outlet = { did: '123', name: '插座', kind: 'outlet', reachable: true, on: false };
const light = { did: '456', name: '台灯', kind: 'light', reachable: true, on: true };

test('reject ambiguous or incomplete device snapshots', () => {
  assert.throws(() => validateDevices([outlet, outlet]));
  assert.throws(() => validateDevices([{ ...outlet, on: null }]));
  assert.throws(() => validateDevices([{ ...outlet, kind: 'cooker' }]));
  assert.doesNotThrow(() => validateDevices([{ ...outlet, reachable: false, on: undefined }]));
  assert.equal(identity('123'), identity('123'));
  assert.notEqual(identity('123'), identity('456'));
});

test('real Matter endpoints: confirmed writes, poll updates, failures, offline and stable IDs', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-matter-'));
  Environment.default.vars.set('storage.path', dir);
  let current = [structuredClone(outlet), structuredClone(light)];
  const writes = [];
  let failure = false;
  let confirm = true;
  const rpc = { async request(method, params) {
    assert.equal(method, 'set');
    writes.push(params);
    if (failure) throw new Error('Device rejected write');
    if (confirm) current.find(d => d.did === params.did).on = params.on;
    return structuredClone(current);
  } };
  let bridge;
  try {
    bridge = await createBridge(rpc, current, { port: 5541, passcode: 20202021, discriminator: 3840 });
    await bridge.node.start();
    assert.match(bridge.node.state.commissioning.pairingCodes.manualPairingCode, /^\d{11}$/);
    const endpoint = bridge.endpoints.get('123');
    const originalNumber = endpoint.number;
    await endpoint.act(agent => agent.get(OnOffServer).on());
    assert.equal(endpoint.state.onOff.onOff, true);
    assert.deepEqual(writes, [{ did: '123', on: true }]);
    current[0].on = false;
    await bridge.sync(current);
    assert.equal(endpoint.state.onOff.onOff, false);
    assert.equal(writes.length, 1, 'poll changes must not issue LAN commands');
    failure = true;
    await assert.rejects(endpoint.act(agent => agent.get(OnOffServer).on()));
    assert.equal(endpoint.state.onOff.onOff, false);
    failure = false;
    confirm = false;
    await assert.rejects(endpoint.act(agent => agent.get(OnOffServer).on()));
    assert.equal(endpoint.state.onOff.onOff, false);
    await bridge.sync([]);
    assert.equal(endpoint.state.bridgedDeviceBasicInformation.reachable, false);
    const before = writes.length;
    await assert.rejects(endpoint.act(agent => agent.get(OnOffServer).on()));
    assert.equal(writes.length, before);
    await bridge.node.close();
    current[0].on = true;
    bridge = await createBridge(rpc, [...current].reverse(), { port: 5541, passcode: 20202021, discriminator: 3840 });
    assert.equal(bridge.endpoints.get('123').number, originalNumber);
    assert.equal(bridge.endpoints.get('123').state.onOff.onOff, true, 'fresh LAN reading must override persisted Matter state');
    assert.equal(bridge.endpoints.get('456').state.onOff.onOff, true);
  } finally {
    await bridge?.node.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('expanded standard device types construct and sync without LAN writes', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-types-'));
  Environment.default.vars.set('storage.path', dir);
  const kinds = ['dimmableLight', 'colorTemperatureLight', 'fan', 'temperature', 'humidity', 'illuminance', 'contact', 'occupancy', 'airPurifier'];
  const devices = kinds.map((kind, i) => ({ did: String(i), name: kind, kind, reachable: true,
    ...(['dimmableLight', 'colorTemperatureLight', 'fan', 'airPurifier'].includes(kind) ? { on: true } : {}),
    attributes: { level: 50, colorTemperature: 250, percent: 40, temperature: 2150, humidity: 4500, illuminance: 10001, contact: true, occupancy: true } }));
  let writes = 0;
  let bridge;
  try {
    bridge = await createBridge({ request() { writes++; throw new Error('Unexpected write'); } }, devices,
      { port: 5541, passcode: 20202021, discriminator: 3840 });
    await bridge.sync(devices);
    assert.equal(writes, 0);
    assert.equal(bridge.endpoints.get('0').state.levelControl.currentLevel, 127);
    assert.equal(bridge.endpoints.get('3').state.temperatureMeasurement.measuredValue, 2150);
    assert.equal(bridge.endpoints.get('4').state.relativeHumidityMeasurement.measuredValue, 4500);
    assert.equal(bridge.endpoints.get('7').state.occupancySensing.occupancy.occupied, true);
    await bridge.sync([]);
    for (const endpoint of bridge.endpoints.values()) assert.equal(endpoint.state.bridgedDeviceBasicInformation.reachable, false);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});

test('brightness, color temperature and fan writes await device confirmation', async () => {
  const { LevelControlServer } = await import('@matter/main/behaviors/level-control');
  const { ColorControlServer } = await import('@matter/main/behaviors/color-control');
  const dir = await mkdtemp(join(tmpdir(), 'mijia-controls-'));
  Environment.default.vars.set('storage.path', dir);
  const devices = [
    { did: 'light', name: 'Light', kind: 'colorTemperatureLight', reachable: true, on: false, attributes: { level: 50, colorTemperature: 250 } },
    { did: 'fan', name: 'Fan', kind: 'fan', reachable: true, on: true, attributes: { percent: 40 } },
  ];
  const writes = [];
  let rejectWrites = false;
  const rpc = { async request(_, params) {
    if (rejectWrites) throw new Error("Device offline");
    writes.push(params);
    const device = devices.find(d => d.did === params.did);
    if (params.property) device.attributes[params.property] = params.value;
    else device.on = params.on;
    return structuredClone(devices);
  } };
  let bridge;
  try {
    bridge = await createBridge(rpc, devices, { port: 5541, passcode: 20202021, discriminator: 3840 });
    const light = bridge.endpoints.get('light');
    await light.act(agent => agent.get(LevelControlServer).moveToLevelWithOnOff({ level: 127, transitionTime: 0 }));
    assert.equal(light.state.onOff.onOff, true);
    assert.equal(light.state.levelControl.currentLevel, 127);
    await light.act(agent => agent.get(ColorControlServer).moveToColorTemperature({ colorTemperatureMireds: 300, transitionTime: 0 }));
    assert.equal(light.state.colorControl.colorTemperatureMireds, 300);
    const fan = bridge.endpoints.get('fan');
    await fan.set({ fanControl: { percentSetting: 75 } });
    assert.equal(devices[1].attributes.percent, 75);
    assert.equal(fan.state.fanControl.percentCurrent, 75);
    rejectWrites = true;
    await assert.rejects(fan.set({ fanControl: { percentSetting: 80 } }));
    assert.equal(fan.state.fanControl.percentCurrent, 75, 'failed write must roll back attributes');
    assert.equal(fan.state.fanControl.percentSetting, 75);
    rejectWrites = false;
    const count = writes.length;
    await bridge.sync(devices);
    assert.equal(writes.length, count);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});
