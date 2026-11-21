import assert from 'node:assert/strict';
import { Environment, Network, NetworkSimulator, MockStorageService, MemoryStorageDriver, Crypto, Entropy,
  ServerNode, ControllerBehavior, Seconds } from '@matter/main';
import { Read } from '@matter/protocol';

export async function collect(result) {
  const reports = [];
  for await (const chunk of result) for await (const report of chunk) reports.push(report);
  return reports;
}
export const read = (peer, paths) => collect(peer.interaction.read({ ...Read({ attributes: paths }), includeKnownVersions: true }));
export function value(reports, endpoint, cluster, attribute) {
  const row = reports.find(r => r.kind === 'attr-value' && r.path.endpointId === endpoint && r.path.clusterId === cluster && r.path.attributeId === attribute);
  assert.ok(row, `Missing attribute ${endpoint}/${cluster}/${attribute}`);
  return row.value;
}
export async function until(condition, timeout = 8000) {
  const end = Date.now() + timeout;
  while (!condition()) { assert.ok(Date.now() < end, 'Expected protocol event'); await new Promise(resolve => setTimeout(resolve, 10)); }
}
export function fixture() {
  const simulator = new NetworkSimulator(), bridgeStorage = {}, controllerStorage = {}, environments = [];
  function environment(id, host, storage) {
    const env = new Environment(id);
    env.set(Network, simulator.addHost(host));
    env.set(Crypto, Environment.default.get(Crypto)); env.set(Entropy, Environment.default.get(Crypto));
    env.vars.set('log.level','error');
    new MockStorageService(env, () => new MemoryStorageDriver(storage)); environments.push(env);
    return env;
  }
  return {
    simulator, bridgeStorage, controllerStorage,
    options: () => ({ environment: environment('bridge-fixture',1,bridgeStorage), passcode:20202021,discriminator:3840,port:5540 }),
    controller: async () => {
      const node = await ServerNode.create(ServerNode.RootEndpointWithoutGroupcast.with(ControllerBehavior), {
        id:'controller-fixture', environment:environment('controller-fixture',2,controllerStorage),
        network:{port:5541},commissioning:{enabled:false},controller:{adminFabricLabel:'Fixture',ble:false},
      });
      await node.start();return node;
    },
    close: async () => { for (const env of environments) await env.close(); },
  };
}
export const commission = controller => controller.peers.commission({passcode:20202021,discriminator:3840,timeout:Seconds(10),autoSubscribe:false});
