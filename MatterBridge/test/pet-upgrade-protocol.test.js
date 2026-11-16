import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Environment, Network, NetworkSimulator, MockStorageService, MemoryStorageDriver, Crypto, Entropy,
  ServerNode, ControllerBehavior, Seconds, Logger } from '@matter/main';
import { Read, Subscribe, Write } from '@matter/protocol';
import { TlvBoolean } from '@matter/types';
import { createBridge, identity } from '../src/bridge.js';

Logger.level = 'error';

const original = [{ did: 'old-lamp', sourceID: 'old-lamp', sourceName: '台灯', name: '台灯', kind: 'light', reachable: true, on: true }];
const additions = () => [
  { did: 'pet-water:waterShortage', sourceID: 'pet-water', sourceName: '宠物饮水机', name: '缺水状态',
    kind: 'waterShortage', reachable: true, attributes: { waterShortage: false } },
  { did: 'pet-food:foodShortage', sourceID: 'pet-food', sourceName: '宠物喂食器', name: '缺粮状态',
    kind: 'foodShortage', reachable: true, attributes: { foodShortage: false } },
];
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

test('a commissioned controller reconnects after upgrade, reads new Descriptor endpoints and subscribes to read-only statuses', { timeout: 40_000 }, async () => {
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
    bridge = await createBridge(rpc, original, options());
    await bridge.node.start();
    controller = await createController();
    await controller.start();
    let peer = await controller.peers.commission({ passcode: 20202021, discriminator: 3840, timeout: Seconds(10), autoSubscribe: false });
    const fabrics = structuredClone(bridge.node.state.commissioning.fabrics);
    assert.equal(Object.keys(fabrics).length, 1);
    const address = { ...peer.peerAddress };
    const oldNumber = bridge.endpoints.get('old-lamp').number;
    const rootBefore = value(await read(peer, [{ endpointId: 0, clusterId: 0x1d, attributeId: 3 }]), 0, 0x1d, 3);
    assert.ok(rootBefore.includes(oldNumber));
    await controller.close();
    await bridge.node.close();

    const added = additions(), upgraded = [...original, ...added];
    bridge = await createBridge(rpc, upgraded, options());
    assert.deepEqual(bridge.node.state.commissioning.fabrics, fabrics);
    assert.equal(bridge.endpoints.get('old-lamp').number, oldNumber);
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
    assert.equal(value(await read(peer, [{ endpointId: water, clusterId: 0x45, attributeId: 0 }]), water, 0x45, 0), true);
    await bridge.sync([...original, ...added.map(d => ({ ...d, reachable: false, attributes: {} }))]);
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
