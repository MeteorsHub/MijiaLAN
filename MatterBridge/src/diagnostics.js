import { randomUUID } from 'node:crypto';
import { ExchangeManager, SessionManager } from '@matter/protocol';
import { TlvReadRequest, TlvSubscribeRequest, TlvSubscribeResponse, TlvDataReport, TlvStatusResponse } from '@matter/types';

// Version-pinned instance adapters for matter.js 0.18.0. Never consume its free-form logger.
// Only public protocol methods are wrapped; their arguments, results, errors and counters are unchanged.
const allowed = new Set([0x1d, 0x28, 0x39, 6, 8, 0x300, 0x102, 0x201, 0x202, 0x402, 0x405, 0x400, 0x406, 0x45]);
const events = new Set(['started','layout','layoutChanged','configuration','snapshot','attributeInput','attributeCommitted',
  'readRequest','subscribeRequest','subscriptionEstablished','subscriptionAttached','subscriptionResumed','subscriptionClosed','reportQueued','reportSent',
  'transportAck','statusAck','exchangeClosed','protocolFailure','rpcRequest','rpcResult','commandFailed','commandConfirmed']);
export function failureReason(error) {
  if (/Timeout|Missing|Unresponsive/.test(error?.constructor?.name ?? '')) return 'timeout';
  if (/Cancel|Abort|Closed|Shutdown/.test(error?.constructor?.name ?? '')) return 'cancelled';
  return 'transport';
}
const int = (n, max = 0xffffffff) => Number.isSafeInteger(n) && n >= 0 && n <= max ? n : undefined;

export class MatterDiagnostics {
  #write; #origin = performance.now(); #sequence = 0; #sessions = new WeakMap(); #exchanges = new WeakMap();
  #nextSession = 0; #nextExchange = 0; #seen = new WeakSet(); #channels = new WeakSet(); #node; #endpoints = new Map();
  #closedSubscriptions = new WeakSet(); #watchedSubscriptions = new WeakSet(); #closeReasons = new WeakMap(); #subscriptionSessions = new WeakMap();
  #unsub = []; #sent = new WeakMap(); #snapshot = 0;
  constructor(write = () => {}) { this.#write = write; this.run = randomUUID(); }
  emit(event, fields = {}) {
    if (!events.has(event)) return;
    // Typed projection is repeated at the App boundary. No caller's arbitrary strings or nested payloads escape.
    const out = { event, run: this.run, sequence: ++this.#sequence, milliseconds: Math.round(performance.now() - this.#origin) };
    for (const key of ['snapshot','device','endpoint','parent','cluster','attribute','dataVersion','configurationVersion',
      'previousVersion','previousEndpoint','session','exchange','subscription','message','ackedMessage','retry',
      'status','minSeconds','maxSeconds','request','count','messageType']) if (int(fields[key]) !== undefined) out[key] = fields[key];
    if (Number.isFinite(fields.value) && Math.abs(fields.value) <= 0xffffffff) out.value = fields.value;
    if (typeof fields.boolean === 'boolean') out.boolean = fields.boolean;
    for (const key of ['isNull','reachable','caseSession','duplicate','changed','native','messageBoundary']) if (typeof fields[key] === 'boolean') out[key] = fields[key];
    for (const key of ['numbers','deviceTypes','parts']) if (Array.isArray(fields[key])) out[key] = fields[key].filter(n => int(n) !== undefined).slice(0, 64);
    if (['unavailable','timeout','cancelled','transport','removed','layout','unchanged','missingCluster'].includes(fields.reason)) out.reason = fields.reason;
    if (typeof fields.signature === 'string' && /^[a-f0-9]{64}$/.test(fields.signature)) out.signature = fields.signature;
    try { this.#write(out); } catch { /* Diagnostics cannot change Matter behavior. */ }
  }
  bind(endpoint, device) { this.#endpoints.set(endpoint.number, { endpoint, device: device?.logAlias }); }
  nextSnapshot() { return ++this.#snapshot; }
  #context(exchange) {
    if (!this.#sessions.has(exchange.session)) this.#sessions.set(exchange.session, ++this.#nextSession);
    if (!this.#exchanges.has(exchange)) this.#exchanges.set(exchange, ++this.#nextExchange);
    return { session: this.#sessions.get(exchange.session), exchange: this.#exchanges.get(exchange), caseSession: exchange.session.isPase === false };
  }
  path(event, path, fields = {}) {
    const endpoint = int(path?.endpointId, 65535), cluster = int(path?.clusterId), attribute = int(path?.attributeId);
    this.emit(event, { ...fields, snapshot: this.#snapshot, endpoint, cluster, attribute, device: this.#endpoints.get(endpoint)?.device });
  }
  #value(path, data) {
    if (!allowed.has(path.clusterId)) return {};
    try {
      const type = this.#node.protocol[path.endpointId]?.[path.clusterId]?.type.attributes[path.attributeId];
      const value = type?.tlv.decodeTlv(data);
      if (value === null) return { isNull: true };
      if (typeof value === 'boolean') return { boolean: value };
      if (typeof value === 'number') return { value };
      if (Array.isArray(value) && path.clusterId === 0x1d) return { numbers: value.map(v => typeof v === 'number' ? v : v?.deviceType) };
      // No names, labels, arbitrary strings, keys, node IDs or unreviewed structures.
      return {};
    } catch { return {}; }
  }
  #report(event, message, context, extra = {}) {
    if (message.payloadHeader.protocolId !== 1 || message.payloadHeader.messageType !== 5) return;
    try {
      const report = TlvDataReport.decode(message.payload);
      const fields = { ...context, ...extra, subscription: report.subscriptionId, message: message.packetHeader.messageId, messageType: 5 };
      this.emit(event, { ...fields, messageBoundary:true, count: report.attributeReports?.length ?? 0 });
      for (const row of (report.attributeReports ?? []).slice(0, 64)) {
        const data = row.attributeData, status = row.attributeStatus;
        if (data) this.path(event, data.path, { ...fields, messageBoundary:false, dataVersion: data.dataVersion, ...this.#value(data.path, data.data) });
        if (status) this.path(event, status.path, { ...fields, messageBoundary:false, status: status.status.status });
      }
    } catch { this.emit('protocolFailure', { ...context, reason: 'transport' }); }
  }
  #received(exchange, message, duplicate = false) {
    const context = this.#context(exchange), h = message.payloadHeader;
    if (!duplicate && h.ackedMessageId !== undefined && this.#sent.get(exchange)?.has(h.ackedMessageId))
      this.emit('transportAck', { ...context, ackedMessage: h.ackedMessageId });
    if (h.protocolId !== 1) return;
    try {
      if (h.messageType === 1) this.emit('statusAck', { ...context, status: TlvStatusResponse.decode(message.payload).status, duplicate });
      if (h.messageType === 2 || h.messageType === 3) {
        const r = (h.messageType === 2 ? TlvReadRequest : TlvSubscribeRequest).decode(message.payload);
        for (const path of (r.attributeRequests ?? []).slice(0, 64)) this.path(h.messageType === 2 ? 'readRequest' : 'subscribeRequest', path,
          { ...context, minSeconds: r.minIntervalFloorSeconds, maxSeconds: r.maxIntervalCeilingSeconds, duplicate });
      }
    } catch { this.emit('protocolFailure', { ...context, reason: 'transport' }); }
  }
  #attach(exchange, initialMessage) {
    if (this.#seen.has(exchange)) return;
    this.#seen.add(exchange); const diagnostics = this;
    const context = this.#context(exchange);
    const receive = exchange.onMessageReceived;
    exchange.onMessageReceived = function(message, duplicate) {
      diagnostics.#received(this, message, duplicate);
      return receive.call(this, message, duplicate);
    };
    if (initialMessage) this.#received(exchange, initialMessage);
    const send = exchange.send;
    exchange.send = async function(type, payload, options) {
      const pseudo = { payloadHeader: { protocolId: 1, messageType: type }, packetHeader: {}, payload };
      diagnostics.#report('reportQueued', pseudo, context);
      try { return await send.call(this, type, payload, options); }
      catch (error) { diagnostics.emit('protocolFailure', { ...context, reason: failureReason(error) }); throw error; }
    };
    const close=exchange.close;
    exchange.close=function(cause) { if(cause)diagnostics.#closeReasons.set(this,failureReason(cause));return close.call(this,cause); };
    exchange.closed.on(() => this.emit('exchangeClosed', {...context,reason:this.#closeReasons.get(exchange)}));
    const channel = exchange.channel;
    if (!this.#channels.has(channel)) {
      this.#channels.add(channel); const transmit = channel.send;
      channel.send = async function(message, options) {
        const ex = options?.exchange;
        const ctx = ex ? diagnostics.#context(ex) : {};
        const h = message.payloadHeader;
        // The channel resolves only after handing the encrypted packet to its transport.
        try {
          const result = await transmit.call(this, message, options);
          if (h.protocolId === 1) {
            if (ex && h.messageType === 5) {
              let ids = diagnostics.#sent.get(ex);
              if (!ids) diagnostics.#sent.set(ex, ids = new Set());
              ids.add(message.packetHeader.messageId);
              diagnostics.#report('reportSent', message, ctx, { retry: options?.logContext?.['retrans#'] ?? 0 });
            }
            if (h.messageType === 4) {
              const s = TlvSubscribeResponse.decode(message.payload);
              diagnostics.emit('subscriptionEstablished', { ...ctx, subscription: s.subscriptionId, maxSeconds: s.maxInterval });
            }
          }
          return result;
        } catch (error) { diagnostics.emit('protocolFailure', { ...ctx, reason: failureReason(error) }); throw error; }
      };
    }
  }
  install(node) {
    this.#node = node;
    const manager = node.env.get(ExchangeManager), diagnostics = this;
    const add = manager.addProtocolHandler;
    manager.addProtocolHandler = function(handler) {
      if (handler.id === 1) {
        const incoming = handler.onNewExchange;
        handler.onNewExchange = function(exchange, message) { diagnostics.#attach(exchange, message); return incoming.call(this, exchange, message); };
      }
      return add.call(this, handler);
    };
    const initiate = manager.initiateExchangeForSession;
    manager.initiateExchangeForSession = function(session, protocol, options) {
      const exchange = initiate.call(this, session, protocol, options);
      if (protocol === 1) diagnostics.#attach(exchange);
      return exchange;
    };
    const sessions = node.env.get(SessionManager);
    const subscription = (session, item) => {
      if (!this.#sessions.has(session)) this.#sessions.set(session, ++this.#nextSession);
      const context={session:this.#sessions.get(session),caseSession:session.isPase===false,subscription:item.subscriptionId};
      const closed=()=>{if(!this.#closedSubscriptions.has(item)){this.#closedSubscriptions.add(item);this.emit('subscriptionClosed',{...context,reason:'removed'});}};
      if (!session.subscriptions.has(item)) closed();
      else {
        if (!this.#watchedSubscriptions.has(item)) {this.#watchedSubscriptions.add(item);item.cancelled?.once(closed);}
        const prior=this.#subscriptionSessions.get(item);
        this.#subscriptionSessions.set(item,context.session);
        this.emit(prior!==undefined&&prior!==context.session?'subscriptionResumed':'subscriptionAttached', {...context,
          minSeconds:item.request?.minIntervalFloorSeconds,maxSeconds:item.request?.maxIntervalCeilingSeconds});
      }
    };
    sessions.subscriptionsChanged.on(subscription);
    const changed = (endpoint, cluster, attributes, dataVersion) => {
      for (const attribute of attributes.slice(0, 64)) if (allowed.has(cluster)) this.path('attributeCommitted', { endpointId: endpoint, clusterId: cluster, attributeId: attribute }, { dataVersion });
    };
    node.protocol.attrsChanged.on(changed);
    this.#unsub.push(() => sessions.subscriptionsChanged.off(subscription), () => node.protocol.attrsChanged.off(changed));
    node.lifecycle.destroyed.on(() => { for (const off of this.#unsub) off(); });
    this.emit('started');
  }
}
