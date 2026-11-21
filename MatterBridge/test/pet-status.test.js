import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Environment, Logger } from '@matter/main';
import { BooleanStateServer } from '@matter/main/behaviors/boolean-state';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { createBridge, identity, validateDevices } from '../src/bridge.js';

Logger.level = 'error';
export const petDevices = () => [
  { did: 'water:waterShortage', sourceID: 'water', sourceName: '宠物饮水机', name: '宠物饮水机 · 缺水状态',
    kind: 'waterShortage', reachable: true, attributes: { waterShortage: false } },
  { did: 'food:foodShortage', sourceID: 'food', sourceName: '宠物喂食器', name: '宠物喂食器 · 缺粮状态',
    kind: 'foodShortage', reachable: true, attributes: { foodShortage: false } },
];

test('shortage sensors expose read-only Boolean State, independent statuses and strict cache availability', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-pet-state-'));
  Environment.default.vars.set('storage.path', dir);
  const devices = petDevices();
  let bridge, calls = 0;
  try {
    bridge = await createBridge({ request() { calls++; throw new Error('Read-only status must not invoke RPC'); } }, devices,
      { port: 15549, passcode: 20202021, discriminator: 3840 });
    assert.equal(bridge.entities.size, 2);
    for (const d of devices) {
      const endpoint = bridge.endpoints.get(d.did);
      assert.equal(endpoint.type.deviceType, 0x850);
      assert.ok(endpoint.state.descriptor.serverList.includes(0x45));
      assert.ok(!endpoint.state.descriptor.serverList.includes(0x6));
      assert.ok(endpoint.behaviors.has(BooleanStateServer));
      assert.equal(endpoint.behaviors.has(OnOffServer), false);
      assert.equal(endpoint.state.booleanState.stateValue, false);
      assert.equal(endpoint.state.bridgedDeviceBasicInformation.uniqueId, identity(d.sourceID));
      assert.equal(endpoint.state.bridgedDeviceBasicInformation.productName, d.sourceName);
      assert.equal(endpoint.state.bridgedDeviceBasicInformation.reachable, true);
    }
    devices[0].attributes.waterShortage = true;
    await bridge.sync(devices);
    assert.equal(bridge.endpoints.get(devices[0].did).state.booleanState.stateValue, true);
    assert.equal(bridge.endpoints.get(devices[1].did).state.booleanState.stateValue, false);
    const unknown = devices.map(d => ({ ...d, reachable: false, attributes: {} }));
    await bridge.sync(unknown);
    for (const d of unknown) assert.equal(bridge.endpoints.get(d.did).state.bridgedDeviceBasicInformation.reachable, false);
    assert.equal(bridge.endpoints.get(devices[0].did).state.booleanState.stateValue, true); // No synthetic recovery to normal.
    await bridge.sync(devices);
    assert.equal(bridge.endpoints.get(devices[0].did).state.bridgedDeviceBasicInformation.reachable, true);
    for (const d of devices) {
      for (const value of [0, 1, null, 'false', undefined]) {
        assert.throws(() => validateDevices([{ ...d, attributes: { [d.kind]: value } }]));
      }
      assert.doesNotThrow(() => validateDevices([{ ...d, reachable: false, attributes: {} }]));
    }
    assert.equal(calls, 0);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});

test('adding two status entities keeps existing endpoint identities and stable new numbers across reordered restarts', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'mijia-pet-upgrade-'));
  Environment.default.vars.set('storage.path', dir);
  const original = [
    { did: 'light', sourceID: 'light', sourceName: '台灯', name: '台灯', kind: 'light', reachable: true, on: true },
    { did: 'dry', sourceID: 'dry', sourceName: '除湿机', name: '除湿机', kind: 'power', reachable: true, on: false },
    { did: 'dry:humidity', sourceID: 'dry', sourceName: '除湿机', name: '湿度', kind: 'humidity', reachable: true, attributes: { humidity: 4900 } },
  ];
  let bridge;
  const rpc = { request() { throw new Error('Upgrade must not issue device commands'); } };
  try {
    bridge = await createBridge(rpc, original, { port: 15549, passcode: 20202021, discriminator: 3840 });
    const old = new Map([...bridge.endpoints].map(([id, e]) => [id, e.number]));
    const parent = bridge.entities.get('dry').number;
    await bridge.entities.get('light').set({ bridgedDeviceBasicInformation: { nodeLabel: 'My lamp' } });
    await bridge.node.close();
    const upgraded = [...original, ...petDevices()];
    bridge = await createBridge(rpc, upgraded, { port: 15549, passcode: 20202021, discriminator: 3840 });
    for (const [id, number] of old) assert.equal(bridge.endpoints.get(id).number, number);
    assert.equal(bridge.entities.get('dry').number, parent);
    assert.equal(bridge.entities.get('light').state.bridgedDeviceBasicInformation.nodeLabel, 'My lamp');
    const added = new Map(petDevices().map(d => [d.did, bridge.endpoints.get(d.did).number]));
    const aggregate = bridge.node.parts.get('bridge');
    for (const number of added.values()) {
      assert.ok(aggregate.state.descriptor.partsList.includes(number));
      assert.ok(bridge.node.state.descriptor.partsList.includes(number));
      assert.ok(![...old.values(), parent].includes(number));
    }
    await bridge.node.close();
    bridge = await createBridge(rpc, [...upgraded].reverse(), { port: 15549, passcode: 20202021, discriminator: 3840 });
    for (const [id, number] of [...old, ...added]) assert.equal(bridge.endpoints.get(id).number, number);
  } finally { await bridge?.node.close(); await rm(dir, { recursive: true, force: true }); }
});
