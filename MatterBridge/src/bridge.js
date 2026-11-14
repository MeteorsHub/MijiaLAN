import { types, stateFor, controls } from './devices.js';
import { createHash } from 'node:crypto';
import { Endpoint, ServerNode, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
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
        (d.reachable && ['light', 'outlet', 'power', 'thermostat', 'dimmableLight', 'colorTemperatureLight', 'fan', 'airPurifier'].includes(d.kind) && typeof d.on !== 'boolean')) throw new Error('Invalid device snapshot');
    if (d.kind === 'windowCovering' && d.reachable &&
        (!Number.isInteger(d.attributes?.position) || d.attributes.position < 0 || d.attributes.position > 100 ||
         !Number.isInteger(d.attributes?.movement) || d.attributes.movement < 0 || d.attributes.movement > 2)) throw new Error('Invalid covering cache');
    if (d.kind === 'thermostat') {
      const a = d.attributes ?? {};
      if (!Number.isInteger(a.targetTemperatureMin) || !Number.isInteger(a.targetTemperatureMax) ||
          a.targetTemperatureMin < -27315 || a.targetTemperatureMax > 32767 || a.targetTemperatureMin > a.targetTemperatureMax ||
          !Number.isInteger(a.targetTemperatureStep) || a.targetTemperatureStep <= 0 ||
          (d.reachable && (!Number.isInteger(a.temperature) || a.temperature < -27315 || a.temperature > 32767 || !Number.isInteger(a.targetTemperature) ||
            a.targetTemperature < a.targetTemperatureMin || a.targetTemperature > a.targetTemperatureMax))) throw new Error('Invalid thermostat cache');
    }
    ids.add(d.did);
  }
  return devices;
}

export async function createBridge(rpc, devices, options = {}) {
  validateDevices(devices);
  if (!devices.length) throw new Error('No supported device found');
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
        if (device.kind === 'windowCovering') {
          const a = confirmed.attributes;
          const target = property === 'open' ? 100 : property === 'close' ? 0 : value;
          if (a.movement !== 0 || (property !== 'stop' && a.position !== target)) throw new Error('Covering movement not confirmed');
          return confirmed;
        }
        if (property === 'on' && confirmed.on !== value) throw new Error('Device state not confirmed');
        if (property !== 'on' && !Number.isFinite(confirmed.attributes?.[property])) throw new Error('Device state not confirmed');
        return confirmed;
      }
      async function write(behavior, on) { await set('on', on); }
      const type = types[device.kind];
      const behaviors = controls(device, set, syncing);
      if (['light', 'outlet', 'power', 'dimmableLight', 'colorTemperatureLight'].includes(device.kind)) behaviors.push(DevicePower);
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
