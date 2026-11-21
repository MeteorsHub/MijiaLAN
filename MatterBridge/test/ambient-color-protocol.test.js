import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Logger, Seconds } from '@matter/main';
import { BasicInformation } from '@matter/main/clusters/basic-information';
import { ColorControl } from '@matter/main/clusters/color-control';
import { BridgedDeviceBasicInformation } from '@matter/main/clusters/bridged-device-basic-information';
import { Invoke, Subscribe } from '@matter/protocol';
import { MatterDiagnostics } from '../src/diagnostics.js';
import { createBridge } from '../src/bridge.js';
import { ambientColorState, matterXYToRgb, miredsToRgb, rgbToMatterXY } from '../src/ambient-color.js';
import { fixture, commission, read, value, collect, until } from '../test-support/protocol.js';

Logger.level = 'error';

const cfg = BasicInformation.Cluster.attributes.configurationVersion.id;
const bridgedCfg = BridgedDeviceBasicInformation.Cluster.attributes.configurationVersion.id;
const color = 0x300;
const source = { sourceID: 'ceiling', sourceName: 'Fixture ceiling', reachable: true, on: true, kind: 'colorTemperatureLight' };

async function command(peer, endpoint, name, parameters = {}) {
  return collect(peer.interaction.invoke(Invoke({
    endpoint, cluster: ColorControl, command: name,
    fields: { optionsMask: {}, optionsOverride: {}, ...parameters },
  })));
}

test('sRGB primaries, white and Planckian colors round trip with independent Level Control', () => {
  for (const rgb of [0xff0000, 0x00ff00, 0x0000ff, 0xffffff]) {
    assert.equal(matterXYToRgb(...rgbToMatterXY(rgb)), rgb);
  }
  const white = miredsToRgb(250);
  assert.ok(white !== 0xffffff && (white & 255) < ((white >> 8) & 255));
  assert.ok(Math.abs(ambientColorState(white).colorTemperatureMireds - 250) <= 1);
  const [x, y] = rgbToMatterXY(0xffffff);
  assert.ok(Math.abs(x / 65536 - 0.3127) < 0.001);
  assert.ok(Math.abs(y / 65536 - 0.3290) < 0.001);
  assert.throws(() => matterXYToRgb(65535, 65535));
});

test('existing paired compound endpoint upgrades ambient CT to Extended Color Light, with verified RGB writes and wire reports', { timeout: 20000 }, async () => {
  const f = fixture(), writes = [], events = [];
  let bridge, controller, subscription;
  const main = { ...source, did: 'ceiling', name: source.sourceName, functionLabel: 'Main Light',
    attributes: { level: 72, colorTemperature: 250, colorTemperatureMin: 154, colorTemperatureMax: 370 } };
  let ambient = { ...source, did: 'ceiling:light:200', name: source.sourceName + ' · Ambient', functionLabel: 'Ambient Light',
    attributes: { level: 33, colorTemperature: 333, colorTemperatureMin: 154, colorTemperatureMax: 588 } };
  let mismatch = false;
  const rpc = {
    async request(method, params) {
      assert.equal(method, 'set');
      assert.equal(params.did, ambient.did);
      assert.equal(params.property, 'rgb');
      writes.push(params.value);
      if (!mismatch) ambient = { ...ambient, attributes: { ...ambient.attributes, rgb: params.value } };
      return [main, ambient];
    },
  };
  try {
    const options = f.options();
    bridge = await createBridge(rpc, [main, ambient], options);
    await bridge.entities.get('ceiling').set({ bridgedDeviceBasicInformation: { nodeLabel: 'Custom ceiling' } });
    await bridge.node.start();
    controller = await f.controller();
    let peer = await commission(controller);
    const address = { ...peer.peerAddress };
    const root = bridge.entities.get('ceiling').number;
    const mainNumber = bridge.endpoints.get(main.did).number;
    const ambientNumber = bridge.endpoints.get(ambient.did).number;
    const versions = [{ endpointId: 0, clusterId: 0x28, attributeId: cfg }, { endpointId: root, clusterId: 0x39, attributeId: bridgedCfg }];
    const before = await read(peer, versions);
    const oldType = await read(peer, [{ endpointId: ambientNumber, clusterId: 0x1d, attributeId: 0 }]);
    assert.deepEqual(value(oldType, ambientNumber, 0x1d, 0).map(t => t.deviceType), [0x10c]);
    const fabrics = structuredClone(bridge.node.state.commissioning.fabrics);
    const pairing = structuredClone(bridge.node.state.commissioning.pairingCodes);
    const identity = { ...bridge.entities.get('ceiling').state.bridgedDeviceBasicInformation };
    await controller.close(); controller = undefined;
    await bridge.node.close();

    ambient = { ...ambient, kind: 'extendedColorLight', attributes: { level: 33, rgb: 0xff0000 } };
    bridge = await createBridge(rpc, [main, ambient], { ...f.options(), diagnostics: new MatterDiagnostics(event => events.push(event)) });
    assert.equal(bridge.entities.get('ceiling').number, root);
    assert.deepEqual([bridge.endpoints.get(main.did).number, bridge.endpoints.get(ambient.did).number], [mainNumber, ambientNumber]);
    const parentInfo = bridge.entities.get('ceiling').state.bridgedDeviceBasicInformation;
    for (const key of ['nodeLabel', 'productName', 'productLabel', 'uniqueId']) assert.equal(parentInfo[key], identity[key]);
    assert.deepEqual(bridge.node.state.commissioning.fabrics, fabrics);
    assert.deepEqual(bridge.node.state.commissioning.pairingCodes, pairing);
    await bridge.node.start();
    controller = await f.controller();
    peer = controller.peers.get(address);
    await peer.start();

    const after = await read(peer, versions);
    for (const { endpointId, clusterId, attributeId } of versions) {
      assert.equal(value(after, endpointId, clusterId, attributeId), value(before, endpointId, clusterId, attributeId) + 1);
    }

    const paths = [
      { endpointId: root, clusterId: 0x1d, attributeId: 3 },
      { endpointId: ambientNumber, clusterId: 0x1d, attributeId: 0 },
      { endpointId: ambientNumber, clusterId: color, attributeId: 0xfffc },
      { endpointId: ambientNumber, clusterId: color, attributeId: 0xfff9 },
    ];
    const descriptor = await read(peer, paths);
    assert.deepEqual(value(descriptor, root, 0x1d, 3), [mainNumber, ambientNumber].sort((a, b) => a - b));
    assert.deepEqual(value(descriptor, ambientNumber, 0x1d, 0).map(t => t.deviceType), [0x10d]);
    assert.deepEqual(value(descriptor, ambientNumber, color, 0xfffc), { hueSaturation: false, enhancedHue: false, colorLoop: false, xy: true, colorTemperature: true });
    const supported = value(descriptor, ambientNumber, color, 0xfff9);
    for (const id of [7, 8, 9, 10, 0x47, 0x4b, 0x4c]) assert.ok(supported.includes(id));

    const rows = [];
    const attrs = [2, 3, 4, 7, 8].map(attributeId => ({ endpointId: ambientNumber, clusterId: color, attributeId }));
    subscription = await peer.interaction.subscribe({
      ...Subscribe({ attributes: attrs, minIntervalFloor: Seconds(0), maxIntervalCeiling: Seconds(5) }),
      updated: async report => { rows.push(...await collect(report)); },
    });
    const observed = (attribute, reading) => rows.some(row => row.kind === 'attr-value' && row.path.attributeId === attribute && row.value === reading);
    const [redX, redY] = rgbToMatterXY(0xff0000);
    await until(() => observed(3, redX) && observed(4, redY));

    const [colorX, colorY] = rgbToMatterXY(0x00ff00);
    let result = await command(peer, ambientNumber, 'moveToColor', { colorX, colorY, transitionTime: 0 });
    assert.equal(result[0].status, 0);
    assert.deepEqual(writes, [0x00ff00]);
    await until(() => observed(3, colorX) && observed(4, colorY));

    result = await command(peer, ambientNumber, 'moveToColorTemperature', { colorTemperatureMireds: 300, transitionTime: 0 });
    assert.equal(result[0].status, 0);
    assert.deepEqual(writes, [0x00ff00, miredsToRgb(300)]);
    const actualCT = ambientColorState(ambient.attributes.rgb).colorTemperatureMireds;
    assert.ok(Math.abs(actualCT - 300) <= 1);
    await until(() => observed(7, actualCT) && observed(8, 2));
    await bridge.sync([main, ambient]);
    assert.equal(value(await read(peer, attrs), ambientNumber, color, 8), 2);

    // A mismatching reply must fail Matter without updating the port's reported chromaticity.
    mismatch = true;
    result = await command(peer, ambientNumber, 'moveToColor', { colorX: redX, colorY: redY, transitionTime: 0 });
    assert.notEqual(result[0].status, 0);
    assert.equal(value(await read(peer, attrs), ambientNumber, color, 8), 2);
    mismatch = false;

    ambient = { ...ambient, attributes: { ...ambient.attributes, rgb: 0x0000ff } };
    await bridge.sync([main, ambient]);
    const [blueX, blueY] = rgbToMatterXY(0x0000ff);
    await until(() => observed(3, blueX) && observed(4, blueY));
    assert.ok(events.some(row => row.event === 'attributeInput' && row.native && row.endpoint === ambientNumber && row.value === 255));
    assert.ok(events.some(row => row.event === 'reportSent' && row.endpoint === ambientNumber && row.cluster === color &&
      row.attribute === 3 && row.value === blueX && row.subscription !== undefined));
    assert.ok(!JSON.stringify(events).includes('Fixture ceiling'));
    assert.equal(value(await read(peer, attrs), ambientNumber, color, 8), 1);
    assert.equal(value(await read(peer, [{ endpointId: mainNumber, clusterId: color, attributeId: 7 }]), mainNumber, color, 7), 250);
    assert.equal(writes.length, 3);
    const count = writes.length;
    result = await command(peer, ambientNumber, 'stepColor', { stepX: 5000, stepY: 3000, transitionTime: 2 });
    assert.equal(result[0].status, 0);
    await until(() => writes.length > count);
    assert.equal(writes.at(-1), matterXYToRgb(blueX + 5000, blueY + 3000));

    result = await command(peer, ambientNumber, 'moveColorTemperature', {
      moveMode: ColorControl.MoveMode.Up, rate: 12,
      colorTemperatureMinimumMireds: 0, colorTemperatureMaximumMireds: 370,
    });
    assert.equal(result[0].status, 0);
    assert.ok(value(await read(peer, attrs), ambientNumber, color, 2) > 0);
    result = await command(peer, ambientNumber, 'stopMoveStep');
    assert.equal(result[0].status, 0);
    const stopped = writes.length;
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal(value(await read(peer, attrs), ambientNumber, color, 2), 0);
    assert.equal(writes.length, stopped);
  } finally {
    await subscription?.close();
    await controller?.close();
    await bridge?.node.close();
    await f.close();
  }
});
