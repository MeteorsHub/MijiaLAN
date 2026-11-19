import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Environment, Network, NetworkSimulator, MockStorageService, MemoryStorageDriver, Crypto, Entropy,
  ServerNode, ControllerBehavior, Seconds, Logger, Endpoint, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { BridgedNodeEndpoint } from '@matter/main/endpoints/bridged-node';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { FixedLabel } from '@matter/main/clusters/fixed-label';
import { Read, Subscribe, Write } from '@matter/protocol';
import { TlvBoolean } from '@matter/types';
import { createBridge, identity } from '../src/bridge.js';
import { types, stateFor } from '../src/devices.js';

Logger.level = 'error';

const original = [
  { did: 'old-lamp', sourceID: 'old-lamp', sourceName: '台灯', name: '台灯', kind: 'light', functionLabel: '照明', reachable: true, on: true },
  { did: 'heater', sourceID: 'heater', sourceName: '壁炉', name: '壁炉', kind: 'power', functionLabel: '加热电源', reachable: true, on: false },
  { did: 'heater:light:3', sourceID: 'heater', sourceName: '壁炉', name: '壁炉 · 灯光', kind: 'light', functionLabel: '照明', reachable: true, on: true },
  { did: 'towel', sourceID: 'towel', sourceName: '电热毛巾架', name: '电热毛巾架', kind: 'thermostat', functionLabel: '加热温控', reachable: true, on: true,
    attributes: { temperature: 5900, targetTemperature: 6500, targetTemperatureMin: 4000, targetTemperatureMax: 6500, targetTemperatureStep: 500 } },
  { did: 'towel:temperature', sourceID: 'towel', sourceName: '电热毛巾架', name: '电热毛巾架 · 温度', kind: 'temperature', functionLabel: '温度',
    reachable: true, attributes: { temperature: 5900 } },
  { did: 'ceiling', sourceID: 'ceiling', sourceName: '吸顶灯', name: '吸顶灯', kind: 'light', functionLabel: '照明', reachable: true, on: true },
];
const additions = () => [
  { did: 'pet-water:waterShortage', sourceID: 'pet-water', sourceName: '宠物饮水机', name: '缺水状态',
    kind: 'waterShortage', functionLabel: '缺水状态', reachable: true, attributes: { waterShortage: false } },
  { did: 'pet-food:foodShortage', sourceID: 'pet-food', sourceName: '宠物喂食器', name: '缺粮状态',
    kind: 'foodShortage', functionLabel: '缺粮状态', reachable: true, attributes: { foodShortage: false } },
];

// Reproduce the previously deployed grouped layout without either function-label service.
async function oldUnlabelledBridge(options) {
  const node = await ServerNode.create({ id: 'mijialan', environment: options.environment, network: { port: options.port },
    commissioning: { passcode: options.passcode, discriminator: options.discriminator },
    basicInformation: { vendorName: 'MijiaLAN', vendorId: VendorId(0xfff1), productName: 'Matter Bridge', productId: 0x8000,
      nodeLabel: 'MijiaLAN', serialNumber: 'mijialan-bridge' } });
  const aggregator = new Endpoint(AggregatorEndpoint, { id: 'bridge' });
  await node.add(aggregator);
  const parents = new Map();
  for (const source of ['heater', 'towel']) {
    const name = original.find(d => d.sourceID === source).sourceName;
    const parent = new Endpoint(BridgedNodeEndpoint, { id: `entity-${identity(source)}`,
      bridgedDeviceBasicInformation: { nodeLabel: name, productName: name, productLabel: name, uniqueId: identity(source), reachable: true } });
    await aggregator.add(parent);
    await parent.set({ bridgedDeviceBasicInformation: { nodeLabel: source === 'heater' ? '自定义壁炉' : '自定义毛巾架' } });
    parents.set(source, parent);
  }
  const endpoints = new Map();
  for (const d of original) {
    const single = !parents.has(d.sourceID);
    const endpoint = new Endpoint(types[d.kind].with(...(single ? [BridgedDeviceBasicInformationServer] : [])), {
      id: `device-${identity(d.did)}`, ...stateFor(d), ...(single ? { bridgedDeviceBasicInformation: {
        nodeLabel: d.sourceName, productName: d.sourceName, productLabel: d.sourceName, uniqueId: identity(d.sourceID), reachable: true,
      } } : {}),
    });
    await (parents.get(d.sourceID) ?? aggregator).add(endpoint);
    endpoints.set(d.did, endpoint);
    if (d.did === 'ceiling') await endpoint.set({ bridgedDeviceBasicInformation: { nodeLabel: '自定义吸顶灯' } });
  }
  return { node, endpoints, parent: parents.get('heater'), parents };
}
async function collect(result) {
  const reports = [];
  for await (const chunk of result) for await (const report of chunk) reports.push(report);
  return reports;
}
async function read(peer, paths) {
  return collect(peer.interaction.read({ ...Read({ attributes: paths }), includeKnownVersions: true }));
}
function value(reports, endpoint, cluster, attribute) {
  const report = reports.find(r => r.kind === 'attr-value' && r.path.endpointId === endpoint && r.path.clusterId === cluster && r.path.attributeId === attribute);
  assert.ok(report, `Missing wire value ${endpoint}/${cluster}/${attribute}`);
  return report.value;
}
async function until(check) {
  const deadline = Date.now() + 8000;
  while (!check()) { assert.ok(Date.now() < deadline, 'Expected subscribed update'); await new Promise(resolve => setTimeout(resolve, 10)); }
}

test('a commissioned controller keeps its fabric and grouped identities when a duplicate temperature child is removed and status endpoints added', { timeout: 40_000 }, async () => {
  const simulator = new NetworkSimulator();
  const bridgeStorage = {}, controllerStorage = {}, environments = [];
  function environment(id, network, data) {
    // Independent roots are essential: no inherited mDNS/UDP services can use a physical network.
    const env = new Environment(id);
    env.set(Network, network);
    env.set(Crypto, Environment.default.get(Crypto));
    env.set(Entropy, Environment.default.get(Crypto));
    env.vars.set('log.level', 'error');
    new MockStorageService(env, () => new MemoryStorageDriver(data));
    environments.push(env);
    return env;
  }
  // Closing a mock Network detaches its router. A restart needs a fresh host at the same address.
  const options = () => ({ environment: environment('fixture-bridge', simulator.addHost(1), bridgeStorage),
    passcode: 20202021, discriminator: 3840, port: 5540 });
  const createController = () => ServerNode.create(ServerNode.RootEndpointWithoutGroupcast.with(ControllerBehavior), {
    id: 'fixture-controller', environment: environment('fixture-controller', simulator.addHost(2), controllerStorage),
    network: { port: 5541 }, commissioning: { enabled: false }, controller: { adminFabricLabel: 'Fixture', ble: false },
  });
  let bridge, controller, subscription, calls = 0;
  const rpc = { request() { calls++; throw new Error('Sensor traffic must never reach device RPC'); } };
  try {
    bridge = await oldUnlabelledBridge(options());
    await bridge.node.start();
    controller = await createController();
    await controller.start();
    let peer = await controller.peers.commission({ passcode: 20202021, discriminator: 3840, timeout: Seconds(10), autoSubscribe: false });
    const fabrics = structuredClone(bridge.node.state.commissioning.fabrics);
    assert.equal(Object.keys(fabrics).length, 1);
    const address = { ...peer.peerAddress };
    const oldNumber = bridge.endpoints.get('old-lamp').number;
    const oldNumbers = new Map([...bridge.endpoints].map(([id, e]) => [id, e.number]));
    const oldParentNumber = bridge.parent.number;
    const towelParent = bridge.parents.get('towel').number;
    const removedNumber = oldNumbers.get('towel:temperature');
    const rootBefore = value(await read(peer, [{ endpointId: 0, clusterId: 0x1d, attributeId: 3 }]), 0, 0x1d, 3);
    assert.ok(rootBefore.includes(oldNumber));
    await controller.close();
    await bridge.node.close();

    const added = additions();
    const retained = original.filter(d => d.did !== 'towel:temperature').map(d => d.did === 'ceiling'
      ? { ...d, kind: 'colorTemperatureLight', functionLabel: '主灯', attributes: { level: 71, colorTemperature: 250, colorTemperatureMin: 154, colorTemperatureMax: 370 } } : d);
    retained.push({ did: 'ceiling:light:200', sourceID: 'ceiling', sourceName: '吸顶灯', name: '副灯', kind: 'colorTemperatureLight',
      functionLabel: '副灯', reachable: true, on: false, attributes: { level: 35, colorTemperature: 333, colorTemperatureMin: 154, colorTemperatureMax: 588 } });
    const upgraded = [...retained, ...added];
    bridge = await createBridge(rpc, upgraded, options());
    assert.deepEqual(bridge.node.state.commissioning.fabrics, fabrics);
    assert.equal(bridge.endpoints.get('old-lamp').number, oldNumber);
    for (const [id, number] of oldNumbers) if (id !== 'towel:temperature') assert.equal(bridge.endpoints.get(id).number, number);
    assert.equal(bridge.entities.get('heater').number, oldParentNumber);
    assert.equal(bridge.entities.get('heater').state.bridgedDeviceBasicInformation.nodeLabel, '自定义壁炉');
    assert.equal(bridge.entities.get('towel').number, towelParent);
    assert.equal(bridge.entities.get('towel').state.bridgedDeviceBasicInformation.nodeLabel, '自定义毛巾架');
    assert.equal(bridge.entities.get('towel').state.bridgedDeviceBasicInformation.uniqueId, identity('towel'));
    assert.equal(bridge.endpoints.get('towel').behaviors.has(BridgedDeviceBasicInformationServer), false);
    assert.equal(bridge.endpoints.has('towel:temperature'), false);
    assert.equal(bridge.entities.get('ceiling').state.bridgedDeviceBasicInformation.nodeLabel, '自定义吸顶灯');
    assert.equal(bridge.entities.get('ceiling').state.bridgedDeviceBasicInformation.uniqueId, identity('ceiling'));
    assert.equal(bridge.endpoints.get('ceiling').number, oldNumbers.get('ceiling'));
    assert.notEqual(bridge.endpoints.get('ceiling'), bridge.entities.get('ceiling'));
    assert.equal(bridge.endpoints.get('ceiling').behaviors.has(BridgedDeviceBasicInformationServer), false);
    assert.ok(![...oldNumbers.values()].includes(bridge.endpoints.get('ceiling:light:200').number));
    assert.equal(bridge.entities.get('old-lamp').state.bridgedDeviceBasicInformation.uniqueId, identity('old-lamp'));
    await bridge.node.start();
    // A controller restart drops the old transport session but retains its commissioned peer and fabric.
    controller = await createController();
    await controller.start();
    peer = controller.peers.get(address);
    assert.ok(peer);
    await peer.start(); // Existing peer/fabric; no second commissioning or pairing reset.
    assert.deepEqual(peer.peerAddress, address);
    const aggregateNumber = bridge.node.parts.get('bridge').number;
    const paths = [0, aggregateNumber].map(endpointId => ({ endpointId, clusterId: 0x1d, attributeId: 3 }));
    const descriptors = await read(peer, paths);
    for (const d of upgraded) {
      const number = bridge.endpoints.get(d.did).number;
      const labels = await read(peer, [{ endpointId: number, clusterId: 0x40, attributeId: 0 },
        { endpointId: number, clusterId: 0x1d, attributeId: 4 }]);
      assert.equal(value(labels, number, 0x40, 0).find(l => l.label === 'function').value, d.functionLabel);
      assert.ok(value(labels, number, 0x1d, 4).some(t => t.mfgCode === 0xfff1 && t.namespaceId === 1 && t.label === d.functionLabel));
    }
    assert.ok(!value(descriptors, 0, 0x1d, 3).includes(removedNumber));
    assert.ok(!value(descriptors, aggregateNumber, 0x1d, 3).includes(removedNumber));
    const remaining = await read(peer, [{ endpointId: towelParent, clusterId: 0x1d, attributeId: 3 }]);
    assert.deepEqual(value(remaining, towelParent, 0x1d, 3), [oldNumbers.get('towel')]);
    const missing = await read(peer, [{ endpointId: removedNumber, clusterId: 0x1d, attributeId: 3 }]);
    assert.ok(missing.some(r => r.kind === 'attr-status' && r.status === 0x7f)); // UnsupportedEndpoint.
    for (const d of added) {
      const number = bridge.endpoints.get(d.did).number;
      assert.ok(value(descriptors, 0, 0x1d, 3).includes(number));
      assert.ok(value(descriptors, aggregateNumber, 0x1d, 3).includes(number));
      const reports = await read(peer, [
        { endpointId: number, clusterId: 0x1d, attributeId: 0 },
        { endpointId: number, clusterId: 0x1d, attributeId: 1 },
        { endpointId: number, clusterId: 0x45, attributeId: 0 },
      ]);
      assert.ok(value(reports, number, 0x1d, 0).some(type => type.deviceType === 0x850));
      assert.ok(value(reports, number, 0x1d, 1).includes(0x45));
      assert.ok(!value(reports, number, 0x1d, 1).includes(0x6));
      assert.equal(value(reports, number, 0x45, 0), false);
    }
    const received = new Map();
    subscription = await peer.interaction.subscribe({
      ...Subscribe({ attributes: [{ clusterId: 0x45, attributeId: 0 }], minIntervalFloor: Seconds(0), maxIntervalCeiling: Seconds(5) }),
      includeKnownVersions: true,
      updated: async result => {
        for (const report of await collect(result)) if (report.kind === 'attr-value') received.set(report.path.endpointId, report.value);
      },
    });
    const water = bridge.endpoints.get(added[0].did).number, food = bridge.endpoints.get(added[1].did).number;
    await until(() => received.get(water) === false && received.get(food) === false);
    added[0].attributes.waterShortage = true;
    await bridge.sync(upgraded);
    await until(() => received.get(water) === true);
    assert.equal(received.get(food), false);
    // Test the remote write boundary, rather than just invoking the server behavior locally.
    const denied = await peer.interaction.write(Write({ writes: [{ path: { endpointId: water, clusterId: 0x45, attributeId: 0 }, data: TlvBoolean.encodeTlv(false) }] }));
    assert.equal(denied.length, 1);
    assert.notEqual(denied[0].status, 0);
    const deniedLabel = await peer.interaction.write(Write({ chunkLists: false }, { kind: 'attribute', endpoint: water,
      cluster: FixedLabel, attributes: 'labelList', value: [{ label: 'function', value: 'Changed' }] }));
    assert.equal(deniedLabel.length, 1);
    assert.equal(deniedLabel[0].status, 0x88); // UnsupportedWrite: labels are metadata, not a LAN command.
    assert.equal(value(await read(peer, [{ endpointId: water, clusterId: 0x45, attributeId: 0 }]), water, 0x45, 0), true);
    await bridge.sync([...retained, ...added.map(d => ({ ...d, reachable: false, attributes: {} }))]);
    const unavailable = await read(peer, [{ endpointId: water, clusterId: 0x39, attributeId: 0x11 }]);
    assert.equal(value(unavailable, water, 0x39, 0x11), false);
    assert.equal(calls, 0);
    assert.deepEqual(bridge.node.state.commissioning.fabrics, fabrics);
  } finally {
    await subscription?.close();
    await controller?.close();
    await bridge?.node.close();
    for (const env of environments) env[Symbol.dispose]();
  }
});
