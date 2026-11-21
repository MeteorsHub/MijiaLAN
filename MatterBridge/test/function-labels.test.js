import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Environment, Logger } from '@matter/main';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { createBridge, validateDevices } from '../src/bridge.js';
import { types } from '../src/devices.js';

Logger.level = 'error';
const options = { port: 15550, passcode: 20202021, discriminator: 3840 };
const device = (did, kind, functionLabel, extra = {}) => ({ did, sourceID: did, sourceName: '实体设备', name: '实体设备',
  kind, functionLabel, reachable: true, on: false, ...extra });

test('function labels name heater, lighting and sensor endpoints without creating identities or changing write routes', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'mijia-function-labels-'));
  Environment.default.vars.set('storage.path', directory);
  let bridge;
  const current = [device('heater', 'power', '加热电源', { sourceName: '壁炉', name: '壁炉' }),
    device('heater:light:3', 'light', '照明', { sourceID: 'heater', sourceName: '壁炉', name: '壁炉 · 灯光' }),
    device('dry', 'power', '电源', { sourceName: '除湿机' }),
    device('dry:temperature', 'temperature', '温度', { sourceID: 'dry', sourceName: '除湿机', attributes: { temperature: 2150 } }),
    device('dry:humidity', 'humidity', '湿度', { sourceID: 'dry', sourceName: '除湿机', attributes: { humidity: 4900 } }),
    device('pet:waterShortage', 'waterShortage', '缺水状态', { sourceID: 'pet', sourceName: '饮水机', attributes: { waterShortage: false } })];
  const writes = [];
  try {
    bridge = await createBridge({ async request(method, params) {
      assert.equal(method, 'set'); writes.push(params);
      current.find(d => d.did === params.did).on = params.on;
      return structuredClone(current);
    } }, current, options);
    for (const d of current) {
      const e = bridge.endpoints.get(d.did);
      assert.equal(e.state.fixedLabel.labelList.find(l => l.label === 'function').value, d.functionLabel);
      assert.ok(e.state.descriptor.serverList.includes(0x40));
      assert.equal(e.state.descriptor.featureMap.tagList, true);
      const tags = e.state.descriptor.tagList;
      assert.ok(tags.some(t => t.mfgCode === null && t.namespaceId === 7 && t.tag >= 1 && t.tag <= 30));
      assert.ok(tags.some(t => t.mfgCode === 0xfff1 && t.namespaceId === 1 && t.label === d.functionLabel));
      if (d.sourceID !== 'pet') assert.equal(e.behaviors.has(BridgedDeviceBasicInformationServer), false);
    }
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.nodeLabel, '壁炉');
    await bridge.entities.get('heater').set({ bridgedDeviceBasicInformation: { nodeLabel: '自定义壁炉' } });
    await bridge.endpoints.get('heater').act(agent => agent.get(OnOffServer).on());
    await bridge.endpoints.get('heater:light:3').act(agent => agent.get(OnOffServer).off());
    assert.deepEqual(writes, [{ did: 'heater', on: true }, { did: 'heater:light:3', on: false }]);
    await bridge.sync(current);
    assert.equal(writes.length, 2);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.nodeLabel, '自定义壁炉');
    assert.equal(bridge.endpoints.get('heater').state.fixedLabel.labelList[0].value, '加热电源');
    assert.equal(bridge.endpoints.get('heater:light:3').state.fixedLabel.labelList[0].value, '照明');
  } finally { await bridge?.node.close(); await rm(directory, { recursive: true, force: true }); }
});

test('labels respect UTF-8 byte limits, legacy snapshots get kind labels, and channel tags stay within the standard namespace', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'mijia-label-bounds-'));
  Environment.default.vars.set('storage.path', directory);
  let bridge;
  const long = '温'.repeat(5) + '🪟' + '度'.repeat(30);
  const current = [device('label', 'power', long), device('fallback', 'light', undefined),
    ...Array.from({ length: 31 }, (_, i) => device(`multi:${String(i + 1).padStart(2, '0')}`, 'power', 'Power', { sourceID: 'multi' }))];
  try {
    bridge = await createBridge({ request() { throw new Error('Metadata must not issue commands'); } }, current, options);
    const e = bridge.endpoints.get('label');
    assert.equal(e.state.fixedLabel.labelList[0].value, '温'.repeat(5));
    const tag = e.state.descriptor.tagList.find(t => t.mfgCode !== null);
    assert.ok(Buffer.byteLength(tag.label) <= 64);
    assert.ok(!tag.label.includes('\ufffd'));
    assert.equal(bridge.endpoints.get('fallback').state.fixedLabel.labelList[0].value, 'Lighting');
    assert.equal(bridge.endpoints.get('multi:30').state.descriptor.tagList[0].tag, 30);
    const extra = bridge.endpoints.get('multi:31');
    assert.equal(extra.state.descriptor.featureMap.tagList, false);
    assert.equal(extra.state.fixedLabel.labelList.find(l => l.label === 'channel').value, '31');
    for (const label of ['', '  ', 0, false, null]) assert.throws(() => validateDevices([device('invalid', 'power', label)]));
  } finally { await bridge?.node.close(); await rm(directory, { recursive: true, force: true }); }
});

test('every published device kind has a label fallback, including legacy outlet snapshots', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'mijia-label-families-'));
  Environment.default.vars.set('storage.path', directory);
  let bridge;
  const current = Object.keys(types).map(kind => device(kind, kind, undefined, {
    attributes: { position: 29, movement: 0, temperature: 2150, targetTemperature: 4000, targetTemperatureMin: 3000,
      targetTemperatureMax: 6500, targetTemperatureStep: 500, waterShortage: false, foodShortage: false, rgb: 0xff0000 },
  }));
  try {
    bridge = await createBridge({ request() { throw new Error('Metadata must not issue commands'); } }, current, options);
    for (const d of current) assert.ok(bridge.endpoints.get(d.did).state.fixedLabel.labelList[0].value.length > 0);
    assert.equal(bridge.endpoints.get('outlet').state.fixedLabel.labelList[0].value, 'Outlet');
  } finally { await bridge?.node.close(); await rm(directory, { recursive: true, force: true }); }
});
