import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Endpoint, ServerNode, ServerNodeStore, VendorId, Seconds, Logger } from '@matter/main';
import { AggregatorEndpoint } from '@matter/main/endpoints/aggregator';
import { BridgedNodeEndpoint } from '@matter/main/endpoints/bridged-node';
import { BridgedDeviceBasicInformationServer } from '@matter/main/behaviors/bridged-device-basic-information';
import { BasicInformationServer } from '@matter/main/behaviors/basic-information';
import { WindowCovering } from '@matter/main/clusters/window-covering';
import { BasicInformation } from '@matter/main/clusters/basic-information';
import { Invoke, Subscribe } from '@matter/protocol';
import { createBridge, identity } from '../src/bridge.js';
import { types, stateFor } from '../src/devices.js';
import { MatterDiagnostics } from '../src/diagnostics.js';
import { fixture, commission, read, value, collect, until } from '../test-support/protocol.js';
Logger.level = 'error';
const cfg = BasicInformation.Cluster.attributes.configurationVersion.id;
const ceiling = {did:'private-ceiling',sourceID:'private-ceiling',sourceName:'private-name',name:'private-name',logAlias:4,kind:'light',reachable:false,on:false};
const bright = () => [ { ...ceiling, kind:'colorTemperatureLight',reachable:true,on:true,
  attributes:{level:1,colorTemperature:358,colorTemperatureMin:154,colorTemperatureMax:370}, nativeValues:{level:1,colorTemperature:2793} },
  { ...ceiling,did:ceiling.did+':light:200',kind:'colorTemperatureLight',reachable:true,on:true,
    attributes:{level:100,colorTemperature:250,colorTemperatureMin:154,colorTemperatureMax:588} } ];

// Faithful minimal historical layouts, not a production strategy flag. Stage 54 moves identity to a new parent.
async function historical(options, grouped = false) {
  const node = await ServerNode.create({id:'mijialan',environment:options.environment,network:{port:5540},
    commissioning:{passcode:20202021,discriminator:3840},basicInformation:{vendorName:'MijiaLAN',vendorId:VendorId(0xfff1),
      productName:'Matter Bridge',productId:0x8000,nodeLabel:'MijiaLAN',serialNumber:'mijialan-bridge'}});
  const aggregator = new Endpoint(AggregatorEndpoint,{id:'bridge'});await node.add(aggregator);
  const id = `device-${identity(ceiling.did)}`, store = node.env.get(ServerNodeStore).endpointStores.storeForEndpoint(aggregator);
  const oldNumber = store.existingChildStore(id)?.number;
  let parent=aggregator, main;
  if (grouped) { parent=new Endpoint(BridgedNodeEndpoint,{id:`entity-${identity(ceiling.did)}`,
    bridgedDeviceBasicInformation:{nodeLabel:ceiling.name,uniqueId:identity(ceiling.did),reachable:false}});await aggregator.add(parent); }
  for (const d of grouped?bright():[ceiling]) {
    const primary = d.did===ceiling.did;
    const endpoint=new Endpoint(types[d.kind].with(...(grouped?[]:[BridgedDeviceBasicInformationServer])),{
      id:`device-${identity(d.did)}`, ...(grouped&&primary?{number:oldNumber}:{}),...stateFor(d),
      ...(!grouped?{bridgedDeviceBasicInformation:{nodeLabel:ceiling.name,uniqueId:identity(ceiling.did),reachable:false}}:{})});
    await parent.add(endpoint);if(primary)main=endpoint;
  }
  await (grouped?parent:main).set({bridgedDeviceBasicInformation:{nodeLabel:'Custom ceiling'}});
  return {node,main,parent};
}

test('a cached paired controller keeps the old light/Reachable paths through the previously broken compound migration and sees configuration changes', {timeout:40000}, async()=>{
  const f=fixture(), records=[];let bridge,controller,sub;
  try {
    bridge=await historical(f.options());await bridge.node.start();controller=await f.controller();let peer=await commission(controller);
    const oldNumber=bridge.main.number;
    const cachedReachable={endpointId:oldNumber,clusterId:0x39,attributeId:0x11};
    const cachedVersion=value(await read(peer,[{endpointId:0,clusterId:0x28,attributeId:cfg}]),0,0x28,cfg);
    assert.equal(value(await read(peer,[cachedReachable]),oldNumber,0x39,0x11),false);
    const fabrics=structuredClone(bridge.node.state.commissioning.fabrics), address={...peer.peerAddress};
    await controller.close();controller=undefined;await bridge.node.close();
    bridge=await historical(f.options(),true);await bridge.node.start();
    controller=await f.controller();peer=controller.peers.get(address);await peer.start();
    const unsupported=await read(peer,[cachedReachable]);assert.ok(unsupported.some(r=>r.kind==='attr-status'&&r.status===0xc3));
    const displacedParent=bridge.parent.number, ambient=bridge.parent.parts.get(`device-${identity(ceiling.did+':light:200')}`).number;
    await controller.close();controller=undefined;await bridge.node.close();
    bridge=await createBridge({request(){throw Error('Reads must use cache');}},bright(),{...f.options(),diagnostics:new MatterDiagnostics(r=>records.push(r))});
    assert.equal(bridge.entities.get(ceiling.did),bridge.endpoints.get(ceiling.did));
    assert.equal(bridge.entities.get(ceiling.did).number,oldNumber);
    assert.notEqual(oldNumber,displacedParent);
    assert.equal(bridge.endpoints.get(ceiling.did+':light:200').number,ambient);
    assert.equal(bridge.entities.get(ceiling.did).state.bridgedDeviceBasicInformation.nodeLabel,'Custom ceiling');
    assert.deepEqual(bridge.node.state.commissioning.fabrics,fabrics);
    await bridge.node.start();controller=await f.controller();peer=controller.peers.get(address);await peer.start();
    // The same cached path now works without requiring the controller to discover a different physical node.
    assert.equal(value(await read(peer,[cachedReachable]),oldNumber,0x39,0x11),true);
    assert.equal(value(await read(peer,[{endpointId:oldNumber,clusterId:6,attributeId:0}]),oldNumber,6,0),true);
    assert.ok(bridge.node.state.basicInformation.configurationVersion>cachedVersion);
    const received=[];
    sub=await peer.interaction.subscribe({...Subscribe({attributes:[{endpointId:0,clusterId:0x28,attributeId:cfg}],minIntervalFloor:Seconds(0),maxIntervalCeiling:Seconds(5)}),
      includeKnownVersions:true,updated:async result=>{received.push(...await collect(result));}});
    await until(()=>received.some(r=>r.kind==='attr-value'&&r.value>cachedVersion));
    // Prove actual version reports and standards-based rediscovery on an already commissioned CASE session.
    const version=bridge.node.state.basicInformation.configurationVersion;
    await bridge.node.act(agent=>agent.get(BasicInformationServer).increaseConfigurationVersion());
    await until(()=>received.some(r=>r.kind==='attr-value'&&r.value===version+1));
    const descriptor=await read(peer,[{endpointId:oldNumber,clusterId:0x1d,attributeId:3}]);
    assert.deepEqual(value(descriptor,oldNumber,0x1d,3),[ambient]);
    const childIdentity=await read(peer,[{endpointId:ambient,clusterId:0x39,attributeId:0x11}]);
    assert.ok(childIdentity.some(r=>r.kind==='attr-status'&&r.status===0xc3));
    assert.ok(records.some(r=>r.event==='reportSent'&&r.endpoint===ambient&&r.cluster===0x39&&r.status===0xc3));
    const beforeRestart=bridge.node.state.basicInformation.configurationVersion;
    const ids=[oldNumber,ambient];
    await sub.close();sub=undefined;await controller.close();controller=undefined;await bridge.node.close();
    bridge=await createBridge({request(){throw Error('Unexpected write');}},bright(),f.options());
    assert.equal(bridge.node.state.basicInformation.configurationVersion,beforeRestart);
    assert.deepEqual([bridge.entities.get(ceiling.did).number,bridge.endpoints.get(ceiling.did+':light:200').number],ids);
    assert.ok(records.some(r=>r.event==='layoutChanged'&&r.previousEndpoint===displacedParent&&r.endpoint===oldNumber));
    assert.ok(records.some(r=>r.event==='readRequest'&&r.endpoint===oldNumber&&r.cluster===0x39));
    assert.ok(records.some(r=>r.event==='reportSent'&&r.cluster===0x39&&r.boolean===true));
    assert.ok(records.some(r=>r.event==='reportSent'&&r.cluster===0x28&&r.attribute===cfg&&r.value===version+1));
    const exported=JSON.stringify(records);
    for(const secret of [ceiling.did,ceiling.name,'Custom ceiling','20202021','MT:'])assert.ok(!exported.includes(secret),secret);
  } finally {await sub?.close();await controller?.close();await bridge?.node.close();await f.close();}
});

test('persistent covering subscription recovers after an accepted command has a confirmation timeout; sent reports and versions match cache recovery', {timeout:30000}, async()=>{
  const f=fixture(),records=[];let bridge,controller,sub;let calls=0;
  const d={did:'private-cover',sourceID:'private-cover',name:'Private covering',kind:'windowCovering',logAlias:7,reachable:true,attributes:{position:0,targetPosition:0,movement:0}};
  const rpc={async request(method,params){calls++;assert.equal(method,'set');assert.equal(params.property,'position');assert.equal(params.value,19);throw new Error('Synthetic confirmation timeout');}};
  try {
    bridge=await createBridge(rpc,[d],{...f.options(),diagnostics:new MatterDiagnostics(r=>records.push(r))});await bridge.node.start();
    controller=await f.controller();const peer=await commission(controller),ep=bridge.endpoints.get(d.did).number;
    const received=[];
    sub=await peer.interaction.subscribe({...Subscribe({attributes:[{endpointId:ep,clusterId:0x102},{endpointId:ep,clusterId:0x39,attributeId:0x11}],
      minIntervalFloor:Seconds(0),maxIntervalCeiling:Seconds(5)}),includeKnownVersions:true,updated:async result=>received.push(...await collect(result))});
    const has=(cluster,attribute,v)=>received.some(r=>r.kind==='attr-value'&&r.path.clusterId===cluster&&r.path.attributeId===attribute&&r.value===v);
    await until(()=>has(0x102,14,10000)&&has(0x39,0x11,true));
    const commandResults=[];
    for await (const chunk of peer.interaction.invoke(Invoke({endpoint:ep,cluster:WindowCovering,command:'goToLiftPercentage',fields:{liftPercent100thsValue:8100}}))) commandResults.push(chunk);
    assert.ok(commandResults.length);
    await until(()=>calls===1&&records.some(r=>r.event==='commandFailed'));
    await bridge.sync([{...d,reachable:false,attributes:{position:17,targetPosition:19,movement:1}}]);
    await until(()=>has(0x102,14,null)&&has(0x39,0x11,false));
    const restored={...d,attributes:{position:19,targetPosition:19,movement:0}};
    // Multiple cache requests are serialized; recovery is not hidden behind a stale in-flight sync.
    await Promise.all([bridge.sync([restored]),bridge.sync([restored])]);
    await until(()=>has(0x102,14,8100)&&has(0x102,8,81));
    assert.equal(value(await read(peer,[{endpointId:ep,clusterId:0x102,attributeId:11}]),ep,0x102,11),8100);
    await until(()=>records.some(r=>r.event==='statusAck'&&r.status===0));
    const recovered=received.find(r=>r.kind==='attr-value'&&r.path.clusterId===0x102&&r.path.attributeId===14&&r.value===8100);
    const sent=records.find(r=>r.event==='reportSent'&&r.endpoint===ep&&r.cluster===0x102&&r.attribute===14&&r.value===8100);
    assert.ok(sent&&sent.caseSession===true&&Number.isInteger(sent.dataVersion));
    assert.ok(records.some(r=>r.event==='attributeCommitted'&&r.endpoint===ep&&r.cluster===0x102&&r.dataVersion===sent.dataVersion));
    assert.equal(recovered.version ?? recovered.dataVersion,sent.dataVersion);
    assert.ok(records.some(r=>r.event==='reportQueued'&&r.subscription===sent.subscription));
    assert.ok(records.some(r=>r.event==='transportAck'&&r.session===sent.session));
    assert.ok(records.some(r=>r.event==='subscribeRequest'&&r.minSeconds===0&&r.maxSeconds===5));
    assert.equal(calls,1); // Read, subscriptions, cache recovery and diagnostics issue no additional device RPC.
    await sub.close();sub=undefined;
    sub=await peer.interaction.subscribe({...Subscribe({attributes:[{endpointId:ep,clusterId:0x39,attributeId:0x11}],
      keepSubscriptions:false,minIntervalFloor:Seconds(0),maxIntervalCeiling:Seconds(5)}),updated:async result=>{await collect(result);}});
    await until(()=>records.some(r=>r.event==='subscriptionClosed'));
  } finally {await sub?.close();await controller?.close();await bridge?.node.close();await f.close();}
});

test('real CASE report loss records transport submission, retransmission and timeout separately from protocol acknowledgment', {timeout:40000}, async()=>{
  const f=fixture(),records=[];let bridge,controller,sub,drop=0,dropped=0;
  const d={did:'loss-fixture',name:'Private loss fixture',kind:'windowCovering',logAlias:8,reachable:true,attributes:{position:0,movement:0}};
  f.simulator.router.intercept((packet,route)=>{
    if(packet.kind==='udp'&&packet.sourcePort===5540&&drop!==0){dropped++;if(drop>0)drop--;return;}
    route(packet);
  });
  try {
    bridge=await createBridge({request(){throw Error('No device calls');}},[d],{...f.options(),diagnostics:new MatterDiagnostics(r=>records.push(r))});
    await bridge.node.start();controller=await f.controller();const peer=await commission(controller);
    const ep=bridge.endpoints.get(d.did).number,received=[];
    sub=await peer.interaction.subscribe({...Subscribe({attributes:[{endpointId:ep,clusterId:0x102,attributeId:14}],minIntervalFloor:Seconds(0),maxIntervalCeiling:Seconds(5)}),
      updated:async result=>received.push(...await collect(result))});
    await until(()=>received.some(r=>r.kind==='attr-value'&&r.value===10000));
    drop=1;
    await bridge.sync([{...d,attributes:{position:19,movement:0}}]);
    await until(()=>records.some(r=>r.event==='reportSent'&&r.value===8100&&r.retry>0));
    await until(()=>received.some(r=>r.kind==='attr-value'&&r.value===8100));
    assert.equal(dropped,1);
    const retransmitted=records.find(r=>r.event==='reportSent'&&r.value===8100&&r.retry>0);
    await until(()=>records.some(r=>r.event==='transportAck'&&r.exchange===retransmitted.exchange));
    const mark=records.length;drop=-1;
    await bridge.sync([{...d,attributes:{position:20,movement:0}}]);
    await until(()=>records.slice(mark).some(r=>r.event==='protocolFailure'&&r.reason==='timeout'),30000);
    const failed=records.slice(mark).find(r=>r.event==='reportSent'&&r.value===8000);
    assert.ok(records.slice(mark).some(r=>r.event==='reportSent'&&r.messageBoundary===true&&r.count>0));
    assert.ok(failed);
    assert.ok(!records.slice(mark).some(r=>(r.event==='transportAck'||r.event==='statusAck')&&r.exchange===failed.exchange));
    assert.ok(!received.some(r=>r.kind==='attr-value'&&r.value===8000));
    drop=0;
  } finally {drop=0;await sub?.close();await controller?.close();await bridge?.node.close();await f.close();}
});
