import { types, stateFor, controls } from './devices.js';
import { MatterDiagnostics, failureReason } from './diagnostics.js';
import { BasicInformationServer } from '@matter/main/behaviors/basic-information';
import { createHash } from 'node:crypto';
import { Endpoint, ServerNode, ServerNodeStore, VendorId } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { BridgedNodeEndpoint } from '@matter/main/endpoints/bridged-node';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { OnOffServer } from '@matter/main/behaviors/on-off';
import { DescriptorServer } from '@matter/main/behaviors/descriptor';
import { FixedLabelServer } from '@matter/main/behaviors/fixed-label';

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

// Stable MijiaLAN development-vendor namespace 1 function IDs. Standard Number tags
// describe numbered channels; vendor tags qualify their purpose without inventing standard semantics.
const functions = {
  power: [1, 'Power'], light: [2, 'Lighting'], dimmableLight: [3, 'Lighting'], colorTemperatureLight: [4, 'Lighting'],
  fan: [5, 'Fan'], airPurifier: [6, 'Air Purification'], thermostat: [7, 'Heating Control'], windowCovering: [8, 'Covering'],
  temperature: [9, 'Temperature'], humidity: [10, 'Humidity'], illuminance: [11, 'Illuminance'],
  occupancy: [12, 'Occupancy'], contact: [13, 'Contact'], waterShortage: [14, 'Water Shortage'], foodShortage: [15, 'Food Shortage'],
  outlet: [16, 'Outlet'],
};
function functionMetadata(device, channel) {
  const [tag, fallback] = functions[device.kind];
  const label = device.functionLabel?.trim() || fallback;
  const labels = { labelList: [{ label: 'function', value: truncateUtf8(label, 16) }, { label: 'channel', value: String(channel) }] };
  // CommonNumber defines standard channels 0..30. Larger groups still have FixedLabel,
  // rather than advertising an out-of-range standard tag or a vendor-only TagList.
  const tags = channel <= 30 ? [{ mfgCode: null, namespaceId: 7, tag: channel },
    { mfgCode: VendorId(0xfff1), namespaceId: 1, tag, label: truncateUtf8(label, 64) }] : undefined;
  return { labels, tags };
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
    if (d.functionLabel !== undefined && (typeof d.functionLabel !== 'string' || !d.functionLabel.trim())) throw new Error('Invalid function label');
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
  const diagnostics = options.diagnostics ?? new MatterDiagnostics();
  diagnostics.install(node);
  const endpoints = new Map();
  const entities = new Map();
  const available = new Map(devices.map(d => [d.did, d.reachable]));
  const owners = new Map(devices.map(d => [d.did, physicalID(d)]));
  const syncing = new Set();
  const oldEntities = new Map();
  try {
    const aggregator = new Endpoint(AggregatorEndpoint, { id: 'bridge' });
    await node.add(aggregator);
    const nodeStore = node.env.get(ServerNodeStore);
    const stores = nodeStore.endpointStores;
    const layoutStore = nodeStore.storage.createContext('mijialan-layout-v2');
    const previousLayout = await layoutStore.get('manifest', null);
    const previousVersion = await layoutStore.get('configurationVersion', 1);
    if (previousVersion > node.state.basicInformation.configurationVersion) await node.set({ basicInformation: { configurationVersion: previousVersion } });
    const aggregateStore = stores.storeForEndpoint(aggregator);
    for (const group of physicalGroups(devices)) {
      const entityId = `entity-${identity(group.id)}`;
      const previousEntity = aggregateStore.existingChildStore(entityId);
      const primary = group.functions.find(d => d.did === group.id) ?? group.functions[0];
      const flat = aggregateStore.existingChildStore(endpointID(primary.did));
      oldEntities.set(group.id, previousEntity?.number ?? flat?.number);
      // Matter Device Library §2.5: compound Bridged Nodes use Separate Endpoints.
      // Keep the existing identity endpoint and put every application function on a child.
      const compound = group.functions.length > 1 || previousEntity !== undefined;
      const legacyNumbers = new Map(group.functions.map(d => [d.did, aggregateStore.existingChildStore(endpointID(d.did))?.number]));
      const flatInfo = flat?.initialValues.get('bridgedDeviceBasicInformation');
      const savedInfo = previousEntity?.initialValues.get('bridgedDeviceBasicInformation') ?? flatInfo;
      let parent = aggregator;
      if (compound) {
        const info = names(primary.sourceName ?? primary.name);
        if (typeof savedInfo?.nodeLabel === 'string') info.nodeLabel = truncateUtf8(savedInfo.nodeLabel, 32);
        parent = new Endpoint(BridgedNodeEndpoint, {
          id: entityId,
          bridgedDeviceBasicInformation: {
            ...info, uniqueId: identity(group.id), reachable: group.functions.some(d => d.reachable),
            configurationVersion: savedInfo?.configurationVersion ?? 1,
          },
        });
        await aggregator.add(parent);
        entities.set(group.id, parent);
      }
      for (const [index, device] of group.functions.entries()) {
        // Override commands, not attribute notifications: LAN polls must never write back to the device.
        class DevicePower extends OnOffServer.with("Lighting") {
          async on() { await write(this, true); return super.on(); }
          async off() { await write(this, false); return super.off(); }
          async toggle() { return this.state.onOff ? this.off() : this.on(); }
        }
        async function set(property, value) {
          try {
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
            diagnostics.emit('commandConfirmed', { device:device.logAlias,value:a.position,native:true });
            return confirmed;
          }
          if (property === 'on' && confirmed.on !== value) throw new Error('Device state not confirmed');
          if (property !== 'on' && !Number.isFinite(confirmed.attributes?.[property])) throw new Error('Device state not confirmed');
          diagnostics.emit('commandConfirmed', {device:device.logAlias,boolean:property==='on'?confirmed.on:undefined,value:confirmed.attributes?.[property],native:false});
          return confirmed;
          } catch (error) { diagnostics.emit('commandFailed', { device: device.logAlias, reason: failureReason(error) }); throw error; }
        }
        async function write(behavior, on) { await set('on', on); }
        const type = types[device.kind];
        const behaviors = controls(device, set, syncing, () => available.get(device.did) === true);
        if (['light', 'outlet', 'power', 'dimmableLight', 'colorTemperatureLight'].includes(device.kind)) behaviors.push(DevicePower);
        const nestedStore = compound ? stores.storeForEndpoint(parent).existingChildStore(endpointID(device.did)) : undefined;
        const oldNumber = nestedStore?.number ?? legacyNumbers.get(device.did);
        const metadata = functionMetadata(device, index + 1);
        const endpoint = new Endpoint(type.with(...behaviors, FixedLabelServer,
          ...(metadata.tags ? [DescriptorServer.with('TagList')] : []), ...(compound ? [] : [BridgedDeviceBasicInformationServer])), {
          id: endpointID(device.did),
          // Preserve existing application endpoint numbers when their storage path gains a parent.
          ...(oldNumber === undefined ? {} : { number: oldNumber }),
          ...stateFor(device),
          fixedLabel: metadata.labels,
          ...(metadata.tags ? { descriptor: { tagList: metadata.tags } } : {}),
          ...(!compound ? { bridgedDeviceBasicInformation: {
            // Some controllers use the product name or label when importing bridged endpoints.
            ...names(device.sourceName ?? device.name),
            uniqueId: identity(group.id), reachable: device.reachable, configurationVersion: savedInfo?.configurationVersion ?? 1,
          } } : {}),
        });
        await parent.add(endpoint);
        endpoints.set(device.did, endpoint);
        if (!compound) entities.set(group.id, endpoint);
        diagnostics.bind(endpoint, device);
      }
    }
    function describe(endpoint) {
      return [...node.protocol[endpoint.number]].map(cluster => ({ id:cluster.type.id,
        attributes:[...cluster.type.attributes].map(a=>a.id).sort((a,b)=>a-b),
        commands:[...cluster.type.commands].map(c=>c.id).sort((a,b)=>a-b),
      })).sort((a,b)=>a.id-b.id);
    }
    const layouts = [...entities].map(([source, entity]) => ({
      source: identity(source), endpoint: entity.number,
      functions: [...owners].filter(([, owner]) => owner === source).map(([did]) => {
        const endpoint = endpoints.get(did);
        return { id: identity(did), endpoint: endpoint.number, parent: endpoint.owner.number,
          types: endpoint.state.descriptor.deviceTypeList.map(t => t.deviceType), services: endpoint.state.descriptor.serverList, clusters:describe(endpoint) };
      }).sort((a,b) => a.endpoint-b.endpoint),
    })).sort((a,b) => a.endpoint-b.endpoint);
    const serialized = JSON.stringify(layouts);
    const signature = createHash('sha256').update(JSON.stringify(layouts.map(({source, functions, ...rest}) =>
      ({...rest, functions: functions.map(({id,...f})=>f)})))).digest('hex');
    const changed = previousLayout?.layout !== serialized;
    const hadLayout = previousLayout !== null || Object.keys(node.state.commissioning.fabrics).length > 0;
    const versionBefore = node.state.basicInformation.configurationVersion;
    const oldGroups = new Map((previousLayout?.layout ? JSON.parse(previousLayout.layout) : []).map(g=>[g.source,JSON.stringify(g)]));
    const changedSources = new Set(layouts.filter(g=>oldGroups.get(g.source)!==JSON.stringify(g)).map(g=>g.source));
    if (changed && hadLayout) {
      await node.act(async agent => {
        await agent.get(BasicInformationServer).increaseConfigurationVersion(async context => {
          for (const [source,entity] of entities) if (changedSources.has(identity(source))) {
            const info = entity.agentFor(context).get(BridgedDeviceBasicInformationServer);
            await context.transaction.addResources(info);
            await context.transaction.begin();
            await info.increaseConfigurationVersion(undefined, context);
          }
        });
      });
    }
    const configurationVersion = node.state.basicInformation.configurationVersion;
    await layoutStore.set({ manifest: { layout: serialized }, configurationVersion });
    diagnostics.emit(changed && hadLayout ? 'layoutChanged' : 'layout', { signature, configurationVersion, previousVersion: versionBefore, changed });
    for (const endpoint of [node,aggregator]) diagnostics.emit('layout', {endpoint:endpoint.number,
      parts:endpoint.state.descriptor.partsList, numbers:endpoint.state.descriptor.serverList, deviceTypes:endpoint.state.descriptor.deviceTypeList.map(t=>t.deviceType)});
    for (const layout of layouts) {
      const source = [...entities].find(([,e])=>e.number===layout.endpoint)?.[0];
      const logAlias = devices.find(d=>physicalID(d)===source)?.logAlias;
      const entity = entities.get(source);
      diagnostics.bind(entity, {logAlias});
      diagnostics.emit('layout', {device:logAlias,endpoint:entity.number,parent:aggregator.number,parts:entity.state.descriptor.partsList,
        numbers:entity.state.descriptor.serverList,deviceTypes:entity.state.descriptor.deviceTypeList.map(t=>t.deviceType)});
      for (const f of layout.functions) {
        diagnostics.emit('layout', { device: logAlias, endpoint: f.endpoint, parent: f.parent, numbers: f.services, deviceTypes: f.types, count: f.types.length, configurationVersion });
        for (const c of f.clusters) diagnostics.emit('layout', {device:logAlias,endpoint:f.endpoint,cluster:c.id,numbers:c.attributes});
      }
      if (oldEntities.get(source) !== undefined && oldEntities.get(source) !== layout.endpoint) diagnostics.emit('layoutChanged', { device: logAlias, endpoint: layout.endpoint, previousEndpoint: oldEntities.get(source), parts: entities.get(source).state.descriptor.partsList });
      diagnostics.emit('configuration', { device: logAlias, endpoint: layout.endpoint, configurationVersion: entities.get(source).state.bridgedDeviceBasicInformation.configurationVersion });
    }
    let syncTail = Promise.resolve();
    const lastInputs = new Map();
    const applySnapshot = async snapshot => {
      const round = diagnostics.nextSnapshot();
      const byId = new Map(validateDevices(snapshot).map(d => [d.did, d]));
      const inputs = new Map([...owners].map(([did]) => { const d=byId.get(did); return [did,JSON.stringify(d ? {reachable:d.reachable,on:d.on,attributes:d.attributes,nativeValues:d.nativeValues}:null)]; }));
      diagnostics.emit('snapshot', { snapshot: round, count: byId.size, changed: [...inputs].some(([did,input])=>lastInputs.get(did)!==input) });
      for (const [did, source] of owners) {
        const d = byId.get(did);
        if (d && physicalID(d) !== source) {
          diagnostics.emit('protocolFailure',{device:d.logAlias,reason:'layout'});
          throw new Error('Physical device layout changed; restart the bridge');
        }
        available.set(did, d?.reachable ?? false);
      }
      // Publish a single endpoint's state and Reachable in one transaction.
      // For pure composition parents commit children first, then advertise recovery on the parent.
      for (const [did, endpoint] of endpoints) {
        const d = byId.get(did), source = owners.get(did), entity = entities.get(source);
        const reachable = [...owners].some(([id, owner]) => owner === source && available.get(id));
        const state = d?.reachable ? stateFor(d) : d && ['temperature','humidity','illuminance','windowCovering'].includes(d.kind)
          ? stateFor({ ...d, attributes: {} }) : {};
        if (endpoint === entity) state.bridgedDeviceBasicInformation = { reachable };
        const inputChanged = lastInputs.get(did) !== inputs.get(did);
        if (inputChanged && d?.kind === 'windowCovering') {
          for (const [attribute, value] of [[8,state.windowCovering.currentPositionLiftPercentage], [14,state.windowCovering.currentPositionLiftPercent100ths], [11,state.windowCovering.targetPositionLiftPercent100ths]])
            diagnostics.path('attributeInput', {endpointId:endpoint.number,clusterId:0x102,attributeId:attribute},
              {value: typeof value==='number'?value:undefined,isNull:value===null,reachable,native:false,reason:d.reachable?undefined:'unavailable'});
          diagnostics.emit('attributeInput', { device:d.logAlias, endpoint:endpoint.number, value:d.attributes?.position, reachable, snapshot:round, native:true });
        }
        if (inputChanged && d && ['light','dimmableLight','colorTemperatureLight'].includes(d.kind)) {
          const rows = [[6,0,d.on,d.on], [8,0,d.nativeValues?.level ?? d.attributes?.level,state.levelControl?.currentLevel],
            [0x300,7,d.nativeValues?.colorTemperature ?? d.attributes?.colorTemperature,state.colorControl?.colorTemperatureMireds]];
          for (const [cluster,attribute,input,output] of rows) for (const [native,value] of [[true,input],[false,output]]) if (value !== undefined)
            diagnostics.path('attributeInput', {endpointId:endpoint.number,clusterId:cluster,attributeId:attribute},
              {value:typeof value==='number'?value:undefined,boolean:typeof value==='boolean'?value:undefined,native,reachable,reason:d.reachable?undefined:'unavailable'});
        }
        syncing.add(did);
        try { await endpoint.set(state); lastInputs.set(did, inputs.get(did)); }
        finally { syncing.delete(did); }
      }
      for (const [source, entity] of entities) if (![...endpoints.values()].includes(entity)) {
        const reachable = [...owners].some(([did, owner]) => owner === source && available.get(did));
        await entity.set({ bridgedDeviceBasicInformation: { reachable } });
      }
    };
    const bridge = {
      node, endpoints, entities, diagnostics,
      sync(snapshot) {
        const copy = structuredClone(snapshot);
        const task = syncTail.then(() => applySnapshot(copy));
        syncTail = task.catch(() => {});
        return task;
      },
    };
    await bridge.sync(devices);
    return bridge;
  } catch (error) { await node.close(); throw error; }
}
