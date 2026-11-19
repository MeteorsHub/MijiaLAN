import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Environment, Endpoint, ServerNode, ServerNodeStore, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { createBridge, identity, validateDevices } from '../src/bridge.js';
import { types, stateFor } from '../src/devices.js';

const options = { port: 15548, passcode: 20202021, discriminator: 3840 };
const devices = () => [
  { did: 'heater', sourceID: 'heater', sourceName: '壁炉', name: '壁炉', kind: 'power', reachable: true, on: false },
  { did: 'heater:light:3', sourceID: 'heater', sourceName: '壁炉', name: '壁炉 · 照明', kind: 'light', reachable: true, on: true },
  { did: 'dry', sourceID: 'dry', sourceName: '除湿机', name: '除湿机', kind: 'power', reachable: true, on: true },
  { did: 'dry:temperature', sourceID: 'dry', sourceName: '除湿机', name: '除湿机 · 温度', kind: 'temperature', reachable: true, attributes: { temperature: 2150 } },
  { did: 'dry:humidity', sourceID: 'dry', sourceName: '除湿机', name: '除湿机 · 湿度', kind: 'humidity', reachable: true, attributes: { humidity: 4900 } },
];

test('physical heater/dehumidifier identities contain isolated functional endpoints and exact write routes', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-composition-'));
  Environment.default.vars.set('storage.path', dir);
  const current = devices(), writes = [];
  const rpc = { async request(method, params) {
    assert.equal(method, 'set');
    writes.push(params);
    const d = current.find(d => d.did === params.did);
    assert.ok(d);
    d.on = params.on;
    return structuredClone(current);
  } };
  let bridge;
  try {
    bridge = await createBridge(rpc, current, options);
    assert.equal(bridge.entities.size, 2);
    assert.equal(bridge.node.parts.get('bridge').parts.size, 2);
    for (const [source, parent] of bridge.entities) {
      const functions = current.filter(d => d.sourceID === source);
      assert.equal(parent.type.deviceType, 0x13);
      assert.equal(parent.state.bridgedDeviceBasicInformation.uniqueId, identity(source));
      assert.equal(parent.state.bridgedDeviceBasicInformation.productName, functions[0].sourceName);
      assert.deepEqual([...parent.state.descriptor.partsList].sort((a, b) => a - b),
        functions.map(d => bridge.endpoints.get(d.did).number).sort((a, b) => a - b));
      for (const d of functions) {
        const endpoint = bridge.endpoints.get(d.did);
        assert.equal(endpoint.owner, parent);
        assert.equal(endpoint.behaviors.has(BridgedDeviceBasicInformationServer), false);
      }
    }
    assert.equal(bridge.endpoints.get('dry:temperature').state.temperatureMeasurement.measuredValue, 2150);
    assert.equal(bridge.endpoints.get('dry:humidity').state.relativeHumidityMeasurement.measuredValue, 4900);
    await bridge.endpoints.get('heater').act(agent => agent.get(OnOffServer).on());
    await bridge.endpoints.get('heater:light:3').act(agent => agent.get(OnOffServer).off());
    await bridge.endpoints.get('dry').act(agent => agent.get(OnOffServer).off());
    assert.deepEqual(writes, [{ did: 'heater', on: true }, { did: 'heater:light:3', on: false }, { did: 'dry', on: false }]);
    assert.equal(bridge.endpoints.get('heater').state.onOff.onOff, true);
    assert.equal(bridge.endpoints.get('heater:light:3').state.onOff.onOff, false);
    const before = writes.length;
    current.find(d => d.did === 'dry:humidity').attributes.humidity = 5250;
    current.find(d => d.did === 'heater:light:3').reachable = false;
    current.find(d => d.did === 'dry:temperature').reachable = false;
    await bridge.sync(current);
    assert.equal(writes.length, before);
    assert.equal(bridge.endpoints.get('dry:humidity').state.relativeHumidityMeasurement.measuredValue, 5250);
    assert.equal(bridge.endpoints.get('dry:temperature').state.temperatureMeasurement.measuredValue, null);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.reachable, true);
    await assert.rejects(bridge.endpoints.get('heater:light:3').act(agent => agent.get(OnOffServer).on()));
    assert.equal(writes.length, before);
    await bridge.sync([]);
    for (const parent of bridge.entities.values()) assert.equal(parent.state.bridgedDeviceBasicInformation.reachable, false);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});

test('single-function identity stays on one endpoint; legacy IDs are never split heuristically', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-one-endpoint-'));
  Environment.default.vars.set('storage.path', dir);
  const current = [{ did: 'same', name: 'Original', kind: 'light', reachable: true, on: true },
    { did: 'same:temperature', sourceID: 'same:temperature', sourceName: 'Standalone', name: 'Other', kind: 'temperature', reachable: true, attributes: { temperature: 2200 } }];
  let bridge;
  try {
    bridge = await createBridge({ request() { throw new Error('No commands expected'); } }, current, options);
    assert.equal(bridge.entities.size, 2);
    for (const d of current) {
      const e = bridge.endpoints.get(d.did);
      assert.equal(bridge.entities.get(d.sourceID ?? d.did), e);
      assert.deepEqual([...e.state.descriptor.partsList], []);
      assert.equal(e.state.bridgedDeviceBasicInformation.uniqueId, identity(d.sourceID ?? d.did));
    }
    assert.equal(bridge.endpoints.get('same:temperature').state.bridgedDeviceBasicInformation.productName, 'Standalone');
    await bridge.endpoints.get('same').set({ bridgedDeviceBasicInformation: { nodeLabel: 'Custom' } });
    await bridge.sync(current);
    assert.equal(bridge.endpoints.get('same').state.bridgedDeviceBasicInformation.nodeLabel, 'Custom');
    assert.throws(() => validateDevices([{ ...current[0], sourceID: '' }]));
    assert.throws(() => validateDevices([{ ...current[0], sourceID: 'x', sourceName: 'One' }, { ...current[1], sourceID: 'x', sourceName: 'Two' }]));
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});

// Recreate the old flat topology over the same actual matter.js store, without an old production runtime.
async function legacyFlat(current) {
  const node = await ServerNode.create({ id: 'mijialan', network: { port: options.port }, commissioning: options,
    basicInformation: { vendorName: 'MijiaLAN', vendorId: VendorId(0xfff1), productName: 'Matter Bridge', productId: 0x8000, nodeLabel: 'MijiaLAN', serialNumber: 'mijialan-bridge' } });
  const aggregator = new Endpoint(AggregatorEndpoint, { id: 'bridge' });
  await node.add(aggregator);
  const endpoints = new Map();
  for (const d of current) {
    const endpoint = new Endpoint(types[d.kind].with(BridgedDeviceBasicInformationServer), {
      id: `device-${identity(d.did)}`, ...stateFor(d),
      bridgedDeviceBasicInformation: { nodeLabel: d.name, productName: d.name, productLabel: d.name, uniqueId: identity(d.did), reachable: d.reachable },
    });
    await aggregator.add(endpoint); endpoints.set(d.did, endpoint);
  }
  return { node, endpoints };
}

test('flat-to-compound migration preserves application numbers, primary UniqueID, custom labels and unrelated node storage', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-composition-upgrade-'));
  Environment.default.vars.set('storage.path', dir);
  const current = [...devices(),
    { did: 'sensor:temperature', sourceID: 'sensor', sourceName: '温湿度计', name: '温湿度计 · 温度', kind: 'temperature', reachable: true, attributes: { temperature: 2200 } },
    { did: 'sensor:humidity', sourceID: 'sensor', sourceName: '温湿度计', name: '温湿度计 · 湿度', kind: 'humidity', reachable: true, attributes: { humidity: 5000 } }];
  let bridge;
  try {
    bridge = await legacyFlat(current);
    const numbers = new Map([...bridge.endpoints].map(([id, e]) => [id, e.number]));
    const uid = bridge.endpoints.get('heater').state.bridgedDeviceBasicInformation.uniqueId;
    await bridge.endpoints.get('heater').set({ bridgedDeviceBasicInformation: { nodeLabel: 'Custom fireplace' } });
    await bridge.node.env.get(ServerNodeStore).storage.createContext('composition-test').set('keep', 'node-sentinel');
    await bridge.node.close();
    const rpc = { request() { throw new Error('Migration must not issue commands'); } };
    bridge = await createBridge(rpc, [...current].reverse(), options);
    for (const [id, number] of numbers) assert.equal(bridge.endpoints.get(id).number, number);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.uniqueId, uid);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.nodeLabel, 'Custom fireplace');
    assert.equal(bridge.entities.get('sensor').state.bridgedDeviceBasicInformation.nodeLabel, '温湿度计');
    assert.equal(bridge.entities.get('sensor').state.bridgedDeviceBasicInformation.uniqueId, identity('sensor'));
    assert.equal(await bridge.node.env.get(ServerNodeStore).storage.createContext('composition-test').get('keep'), 'node-sentinel');
    const parentNumber = bridge.entities.get('heater').number;
    await bridge.entities.get('heater').set({ bridgedDeviceBasicInformation: { nodeLabel: 'Grouped custom label' } });
    await bridge.node.close();
    bridge = await createBridge(rpc, current.filter(d => d.did !== 'heater:light:3'), options);
    assert.equal(bridge.entities.get('heater').number, parentNumber);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.nodeLabel, 'Grouped custom label');
    assert.equal(bridge.endpoints.get('heater').number, numbers.get('heater'));
    assert.equal(bridge.endpoints.get('heater'), bridge.entities.get('heater'));
    assert.equal(bridge.endpoints.get('heater').behaviors.has(BridgedDeviceBasicInformationServer), true);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});
