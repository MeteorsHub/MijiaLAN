import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Environment, Logger } from '@matter/main';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { LevelControlServer } from '@matter/main/behaviors/level-control';
import { ColorControlServer } from '@matter/main/behaviors/color-control';
import { createBridge } from '../src/bridge.js';

Logger.level = 'error';
test('main/ambient lighting have isolated power, level, temperature and cache updates inside one physical identity', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'mijia-dual-light-'));
  Environment.default.vars.set('storage.path', directory);
  const current = [
    { did: 'lamp', sourceID: 'lamp', sourceName: '吸顶灯', name: '吸顶灯', functionLabel: '主灯', kind: 'colorTemperatureLight', reachable: true, on: true,
      attributes: { level: 71, colorTemperature: 250, colorTemperatureMin: 154, colorTemperatureMax: 370 } },
    { did: 'lamp:light:200', sourceID: 'lamp', sourceName: '吸顶灯', name: '吸顶灯 · 副灯', functionLabel: '副灯', kind: 'colorTemperatureLight', reachable: true, on: false,
      attributes: { level: 35, colorTemperature: 333, colorTemperatureMin: 154, colorTemperatureMax: 588 } },
  ];
  const writes = [];
  let bridge;
  try {
    bridge = await createBridge({ async request(method, params) {
      assert.equal(method, 'set'); writes.push(params);
      const d = current.find(d => d.did === params.did);
      if (params.property) d.attributes[params.property] = params.value;
      else d.on = params.on;
      return structuredClone(current);
    } }, current, { port: 15555, passcode: 20202021, discriminator: 3840 });
    assert.equal(bridge.entities.size, 1);
    const main = bridge.endpoints.get('lamp'), ambient = bridge.endpoints.get('lamp:light:200');
    assert.equal(main.state.fixedLabel.labelList[0].value, '主灯');
    assert.equal(ambient.state.fixedLabel.labelList[0].value, '副灯');
    await ambient.act(agent => agent.get(OnOffServer).on());
    await ambient.act(agent => agent.get(LevelControlServer).moveToLevel({ level: 127 }));
    await main.act(agent => agent.get(ColorControlServer).moveToColorTemperature({ colorTemperatureMireds: 200 }));
    await ambient.act(agent => agent.get(ColorControlServer).moveToColorTemperature({ colorTemperatureMireds: 400 }));
    await main.act(agent => agent.get(OnOffServer).off());
    assert.deepEqual(writes, [
      { did: 'lamp:light:200', on: true }, { did: 'lamp:light:200', property: 'level', value: 50 },
      { did: 'lamp', property: 'colorTemperature', value: 200 },
      { did: 'lamp:light:200', property: 'colorTemperature', value: 400 }, { did: 'lamp', on: false },
    ]);
    assert.equal(ambient.state.onOff.onOff, true);
    assert.equal(main.state.onOff.onOff, false);
    assert.equal(ambient.state.levelControl.currentLevel, 127);
    current[0].attributes.level = 20;
    await bridge.sync(current);
    assert.equal(main.state.levelControl.currentLevel, 51);
    assert.equal(ambient.state.levelControl.currentLevel, 127);
    assert.equal(writes.length, 5);
    current[1].reachable = false;
    await bridge.sync(current);
    await assert.rejects(ambient.act(agent => agent.get(OnOffServer).off()));
    assert.equal(writes.length, 5);
  } finally { await bridge?.node.close(); await rm(directory, { recursive: true, force: true }); }
});
