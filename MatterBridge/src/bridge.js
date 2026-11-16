import { types, stateFor, controls } from './devices.js';
import { createHash } from 'node:crypto';
import { Endpoint, ServerNode, ServerNodeStore, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { BridgedNodeEndpoint } from '@matter/main/endpoints/bridged-node';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { OnOffServer } from '@matter/main/behaviors/on-off';

export function identity(did) {
  return createHash('sha256').update(did).digest('hex').slice(0, 32);
}

function truncateUtf8(name, byteLimit) {
  let bytes = 0;
  let end = 0;
  for (const character of name) {
    bytes += Buffer.byteLength(character);
    if (bytes > byteLimit) break;
    end += character.length;
  }
  return name.slice(0, end);
}

const physicalID = device => device.sourceID ?? device.did;
const endpointID = did => `device-${identity(did)}`;
function names(name) {
  name = name.trim() || 'MijiaLAN';
  return { nodeLabel: truncateUtf8(name, 32), productName: truncateUtf8(name, 32), productLabel: truncateUtf8(name, 64) };
}

function physicalGroups(devices) {
  const groups = new Map();
  for (const device of devices) {
    const id = physicalID(device);
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(device);
  }
  return [...groups].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([id, functions]) => ({ id, functions: functions.sort((a, b) => a.did < b.did ? -1 : a.did > b.did ? 1 : 0) }));
}

export function validateDevices(devices) {
  if (!Array.isArray(devices)) throw new Error('Invalid device snapshot');
  const ids = new Set();
  const sourceNames = new Map();
  for (const d of devices) {
    if ((d.sourceID !== undefined && (typeof d.sourceID !== 'string' || !d.sourceID)) ||
        (d.sourceName !== undefined && typeof d.sourceName !== 'string')) throw new Error('Invalid physical device identity');
    if (d.sourceName !== undefined) {
      const source = physicalID(d);
      if (sourceNames.has(source) && sourceNames.get(source) !== d.sourceName) throw new Error('Conflicting physical device names');
      sourceNames.set(source, d.sourceName);
    }
    if (typeof d.did !== 'string' || !d.did || ids.has(d.did) ||
        typeof d.name !== 'string' || !Object.hasOwn(types, d.kind) ||
        typeof d.reachable !== 'boolean' || !(d.on == null || typeof d.on === 'boolean') ||
        (d.reachable && ['light', 'outlet', 'power', 'thermostat', 'dimmableLight', 'colorTemperatureLight', 'fan', 'airPurifier'].includes(d.kind) && typeof d.on !== 'boolean')) throw new Error('Invalid device snapshot');
    if (d.kind === 'windowCovering' && d.reachable &&
        (!Number.isInteger(d.attributes?.position) || d.attributes.position < 0 || d.attributes.position > 100 ||
         !Number.isInteger(d.attributes?.movement) || d.attributes.movement < 0 || d.attributes.movement > 2)) throw new Error('Invalid covering cache');
    if (['waterShortage', 'foodShortage'].includes(d.kind) &&
        (d.reachable || d.attributes?.[d.kind] !== undefined) && typeof d.attributes?.[d.kind] !== 'boolean') throw new Error('Invalid shortage cache');
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
  const entities = new Map();
  const available = new Map(devices.map(d => [d.did, d.reachable]));
  const owners = new Map(devices.map(d => [d.did, physicalID(d)]));
  const syncing = new Set();
  try {
    const aggregator = new Endpoint(AggregatorEndpoint, { id: 'bridge' });
    await node.add(aggregator);
    const stores = node.env.get(ServerNodeStore).endpointStores;
    const aggregateStore = stores.storeForEndpoint(aggregator);
    for (const group of physicalGroups(devices)) {
      const entityId = `entity-${identity(group.id)}`;
      const previousEntity = aggregateStore.existingChildStore(entityId);
      // Keep the compound layout if a later schema exposes just one remaining function.
      const compound = group.functions.length > 1 || previousEntity !== undefined;
      let parent = aggregator;
      const legacyNumbers = new Map(group.functions.map(d => [d.did, aggregateStore.existingChildStore(endpointID(d.did))?.number]));
      if (compound) {
        const primary = group.functions.find(d => d.did === group.id) ?? group.functions[0];
        const info = names(primary.sourceName ?? primary.name);
        if (!previousEntity) {
          // Public store API; consume only the obsolete flat root's public label, never fabric state.
          const old = aggregateStore.existingChildStore(endpointID(primary.did));
          const label = old?.createStoreForBehavior('bridgedDeviceBasicInformation').initialValues?.nodeLabel;
          if (typeof label === 'string' && label !== names(primary.name).nodeLabel) info.nodeLabel = truncateUtf8(label, 32);
        }
        parent = new Endpoint(BridgedNodeEndpoint, {
          id: entityId,
          bridgedDeviceBasicInformation: { ...info, uniqueId: identity(group.id), reachable: group.functions.some(d => d.reachable) },
        });
        await aggregator.add(parent);
        entities.set(group.id, parent);
      }
      for (const device of group.functions) {
        // Override commands, not attribute notifications: LAN polls must never write back to the device.
        class DevicePower extends OnOffServer.with("Lighting") {
          async on() { await write(this, true); return super.on(); }
          async off() { await write(this, false); return super.off(); }
          async toggle() { return this.state.onOff ? this.off() : this.on(); }
        }
        async function set(property, value) {
          if (['waterShortage', 'foodShortage'].includes(device.kind)) throw new Error('Read-only sensor');
          if (!available.get(device.did)) throw new Error('Device offline');
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
        const behaviors = controls(device, set, syncing, () => available.get(device.did) === true);
        if (['light', 'outlet', 'power', 'dimmableLight', 'colorTemperatureLight'].includes(device.kind)) behaviors.push(DevicePower);
        const nestedStore = compound ? stores.storeForEndpoint(parent).existingChildStore(endpointID(device.did)) : undefined;
        const oldNumber = nestedStore?.number ?? legacyNumbers.get(device.did);
        const endpoint = new Endpoint(type.with(...behaviors, ...(compound ? [] : [BridgedDeviceBasicInformationServer])), {
          id: endpointID(device.did),
          // Preserve existing application endpoint numbers when their storage path gains a parent.
          ...(oldNumber === undefined ? {} : { number: oldNumber }),
          ...stateFor(device),
          ...(!compound ? { bridgedDeviceBasicInformation: {
            // Some controllers use the product name or label when importing bridged endpoints.
            ...names(device.sourceName ?? device.name),
            uniqueId: identity(group.id), reachable: device.reachable,
          } } : {}),
        });
        await parent.add(endpoint);
        endpoints.set(device.did, endpoint);
        if (!compound) entities.set(group.id, endpoint);
      }
    }
    const bridge = {
      node, endpoints, entities,
      async sync(snapshot) {
        const byId = new Map(validateDevices(snapshot).map(d => [d.did, d]));
        for (const [did, source] of owners) {
          const d = byId.get(did);
          if (d && physicalID(d) !== source) throw new Error('Physical device layout changed; restart the bridge');
          available.set(did, d?.reachable ?? false);
        }
        for (const [source, entity] of entities) {
          const reachable = [...owners].some(([did, owner]) => owner === source && available.get(did));
          await entity.set({ bridgedDeviceBasicInformation: { reachable } });
        }
        for (const [did, endpoint] of endpoints) {
          const d = byId.get(did);
          syncing.add(did);
          try {
            if (d?.reachable) await endpoint.set(stateFor(d));
            else if (d && ['temperature', 'humidity', 'illuminance', 'windowCovering'].includes(d.kind)) {
              await endpoint.set(stateFor({ ...d, attributes: {} }));
            }
          } finally { syncing.delete(did); }
        }
      },
    };
    await bridge.sync(devices);
    return bridge;
  } catch (error) { await node.close(); throw error; }
}
