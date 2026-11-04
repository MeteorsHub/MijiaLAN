import { types, stateFor, controls } from './devices.js';
import { createHash } from 'node:crypto';
import { Endpoint, ServerNode, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { OnOffLightDevice } from '@matter/main/devices/on-off-light';
import { OnOffPlugInUnitDevice } from '@matter/main/devices/on-off-plug-in-unit';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { OnOffServer } from '@matter/main/behaviors/on-off';

export function identity(did) {
  return createHash('sha256').update(did).digest('hex').slice(0, 32);
}

export function validateDevices(devices) {
  if (!Array.isArray(devices)) throw new Error('Invalid device snapshot');
  const ids = new Set();
  for (const d of devices) {
    if (typeof d.did !== 'string' || !d.did || ids.has(d.did) ||
        typeof d.name !== 'string' || !Object.hasOwn(types, d.kind) ||
        typeof d.reachable !== 'boolean' || !(d.on == null || typeof d.on === 'boolean') ||
        (d.reachable && ['light', 'outlet', 'dimmableLight', 'colorTemperatureLight', 'fan', 'airPurifier'].includes(d.kind) && typeof d.on !== 'boolean')) throw new Error('Invalid device snapshot');
    ids.add(d.did);
  }
  return devices;
}

export async function createBridge(rpc, devices, options = {}) {
  validateDevices(devices);
  if (!devices.length) throw new Error('No supported light or outlet found');
  const node = await ServerNode.create({
    id: 'mijialan',
    ...(options.environment ? { environment: options.environment } : {}),
    network: { port: options.port ?? 5540 },
    commissioning: { passcode: options.passcode, discriminator: options.discriminator },
    basicInformation: {
      vendorName: 'MijiaLAN', vendorId: VendorId(0xfff1),
      productName: 'Matter Bridge', productId: 0x8000,
      nodeLabel: 'MijiaLAN', serialNumber: 'mijialan-bridge',
    },
  });
  const endpoints = new Map();
  const syncing = new Set();
  try {
    const aggregator = new Endpoint(AggregatorEndpoint, { id: 'bridge' });
    await node.add(aggregator);
    for (const device of devices) {
      // Override commands, not attribute notifications: LAN polls must never write back to the device.
      class DevicePower extends OnOffServer.with("Lighting") {
        async on() { await write(this, true); return super.on(); }
        async off() { await write(this, false); return super.off(); }
        async toggle() { return this.state.onOff ? this.off() : this.on(); }
      }
      async function set(property, value) {
        const endpoint = endpoints.get(device.did);
        if (endpoint && !endpoint.state.bridgedDeviceBasicInformation.reachable) throw new Error('Device offline');
        const result = validateDevices(await rpc.request('set', property === 'on'
          ? { did: device.did, on: value } : { did: device.did, property, value }));
        const confirmed = result.find(d => d.did === device.did);
        if (!confirmed?.reachable) throw new Error('Device state not confirmed');
        if (property === 'on' && confirmed.on !== value) throw new Error('Device state not confirmed');
        if (property !== 'on' && !Number.isFinite(confirmed.attributes?.[property])) throw new Error('Device state not confirmed');
        return confirmed;
      }
      async function write(behavior, on) { await set('on', on); }
      const type = types[device.kind];
      const behaviors = controls(device, set, syncing);
      if (['light', 'outlet', 'dimmableLight', 'colorTemperatureLight'].includes(device.kind)) behaviors.push(DevicePower);
      const endpoint = new Endpoint(type.with(...behaviors, BridgedDeviceBasicInformationServer), {
        id: `device-${identity(device.did)}`,
        ...stateFor(device),
        bridgedDeviceBasicInformation: {
          nodeLabel: Array.from(device.name).slice(0, 32).join(''),
          uniqueId: identity(device.did), reachable: device.reachable,
        },
      });
      await aggregator.add(endpoint);
      endpoints.set(device.did, endpoint);
    }
    const bridge = {
      node, endpoints,
      async sync(snapshot) {
        const byId = new Map(validateDevices(snapshot).map(d => [d.did, d]));
        for (const [did, endpoint] of endpoints) {
          const d = byId.get(did);
          syncing.add(did);
          try { await endpoint.set({
            bridgedDeviceBasicInformation: { reachable: d?.reachable ?? false },
            ...(d ? stateFor(d) : {}),
          }); } finally { syncing.delete(did); }
        }
      },
    };
    await bridge.sync(devices);
    return bridge;
  } catch (error) { await node.close(); throw error; }
}
