'use strict';
// Webhook parsing, Meta signature check, call-control requests, duplicate / concurrency handling.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { callEvents, metaCalls } = require('../src/meta');
const { vapiClient } = require('../src/vapi');
const { Registry } = require('../src/registry');
const { validMetaSignature } = require('../src/bridge');
const { loadConfig } = require('../src/config');

const connectValue = {
  messaging_product: 'whatsapp',
  metadata: { display_phone_number: '15551488874', phone_number_id: '1330443963491296' },
  contacts: [{ profile: { name: 'Asha' }, wa_id: '919500000001' }],
  calls: [{ id: 'wacid.A', from: '919500000001', to: '15551488874', event: 'connect', timestamp: '1792540000',
            direction: 'USER_INITIATED', session: { sdp_type: 'offer', sdp: 'v=0\r\n' } }],
};
const rawWebhook = { object: 'whatsapp_business_account', entry: [{ id: 'WABA', changes: [{ field: 'calls', value: connectValue }] }] };

test('call events from Meta\'s raw webhook and from an n8n WhatsApp Trigger item look the same', () => {
  const fromRaw = callEvents(rawWebhook);
  const fromN8n = callEvents({ ...connectValue, field: 'calls' });
  assert.deepEqual(fromRaw, fromN8n);
  assert.deepEqual(fromRaw[0], {
    id: 'wacid.A', event: 'connect', direction: 'USER_INITIATED', from: '919500000001', name: 'Asha',
    phoneNumberId: '1330443963491296', timestamp: '1792540000', sdp: 'v=0\r\n', status: undefined, duration: undefined, errors: undefined,
  });
  assert.equal(callEvents([{ ...connectValue, field: 'calls' }, { field: 'messages', messages: [] }]).length, 1, 'n8n batches');
});

test('message webhooks and terminate events', () => {
  assert.deepEqual(callEvents({ object: 'whatsapp_business_account', entry: [{ changes: [{ field: 'messages', value: {} }] }] }), []);
  const [t] = callEvents({ field: 'calls', calls: [{ id: 'wacid.A', event: 'terminate', status: 'COMPLETED', duration: 12 }] });
  assert.equal(t.event, 'terminate');
  assert.equal(t.sdp, null);
  assert.equal(t.duration, 12);
  const [u] = callEvents({ field: 'calls', contacts: [{ user_id: 'IN.123' }], calls: [{ id: 'wacid.U', event: 'connect', from_user_id: 'IN.123' }] });
  assert.equal(u.from, 'IN.123', 'username (BSUID) callers without a phone number');
});

test('Meta signature: only the app secret\'s HMAC of the exact body passes', () => {
  const raw = Buffer.from(JSON.stringify(rawWebhook));
  const sig = 'sha256=' + crypto.createHmac('sha256', 's3cret').update(raw).digest('hex');
  assert.ok(validMetaSignature(raw, sig, 's3cret'));
  assert.ok(!validMetaSignature(raw, sig, 'other'));
  assert.ok(!validMetaSignature(Buffer.from(raw.toString() + ' '), sig, 's3cret'));
  assert.ok(!validMetaSignature(raw, undefined, 's3cret'));
  assert.ok(!validMetaSignature(raw, sig, ''));
});

test('call-control requests match the Calling API', async () => {
  const sent = [];
  const fetchImpl = async (url, opts) => { sent.push({ url, auth: opts.headers.authorization, body: JSON.parse(opts.body) }); return new Response('{"success":true}'); };
  const meta = metaCalls({ graphUrl: 'https://graph.facebook.com/v25.0', phoneNumberId: '133', token: 'T', fetchImpl });
  await meta.preAccept('wacid.A', 'SDP');
  await meta.accept('wacid.A', 'SDP', 'vapi:1');
  await meta.reject('wacid.B');
  await meta.terminate('wacid.A');
  assert.equal(sent[0].url, 'https://graph.facebook.com/v25.0/133/calls');
  assert.equal(sent[0].auth, 'Bearer T');
  assert.deepEqual(sent.map((s) => s.body), [
    { messaging_product: 'whatsapp', call_id: 'wacid.A', action: 'pre_accept', session: { sdp_type: 'answer', sdp: 'SDP' } },
    { messaging_product: 'whatsapp', call_id: 'wacid.A', action: 'accept', session: { sdp_type: 'answer', sdp: 'SDP' }, biz_opaque_callback_data: 'vapi:1' },
    { messaging_product: 'whatsapp', call_id: 'wacid.B', action: 'reject' },
    { messaging_product: 'whatsapp', call_id: 'wacid.A', action: 'terminate' },
  ]);
});

test('Meta errors surface with their message', async () => {
  const fetchImpl = async () => new Response(JSON.stringify({ error: { message: 'Invalid call ID', code: 138003 } }), { status: 400 });
  const meta = metaCalls({ graphUrl: 'x', phoneNumberId: '1', token: 'T', fetchImpl });
  await assert.rejects(meta.accept('nope', 'SDP'), /accept failed \(400\): Invalid call ID/);
});

test('Vapi call: existing assistant, WebSocket transport, 16 kHz PCM, the Meta call ID in metadata', async () => {
  let req;
  const fetchImpl = async (url, opts) => {
    req = { url, auth: opts.headers.authorization, body: JSON.parse(opts.body) };
    return new Response(JSON.stringify({ id: 'vc1', transport: { provider: 'vapi.websocket', websocketCallUrl: 'wss://api.vapi.ai/vc1/transport' } }), { status: 201 });
  };
  const vapi = vapiClient({ privateKey: 'PRIV', assistantId: 'afd96ebf-40a7-40d2-bc0b-b6b94367e588', fetchImpl });
  const out = await vapi.createCall({ metaCallId: 'wacid.A', waId: '919500000001', name: 'Asha' });
  assert.deepEqual(out, { id: 'vc1', websocketCallUrl: 'wss://api.vapi.ai/vc1/transport' });
  assert.equal(req.url, 'https://api.vapi.ai/call');
  assert.equal(req.auth, 'Bearer PRIV');
  assert.equal(req.body.assistantId, 'afd96ebf-40a7-40d2-bc0b-b6b94367e588');
  assert.deepEqual(req.body.transport, { provider: 'vapi.websocket', audioFormat: { format: 'pcm_s16le', container: 'raw', sampleRate: 16000 } });
  assert.equal(req.body.assistantOverrides.metadata.metaCallId, 'wacid.A');
  assert.equal(req.body.assistantOverrides.server, undefined, 'the dashboard server URL is kept unless VAPI_SERVER_URL is set');
  assert.equal(req.body.phoneNumberId, undefined, 'phone fields are not allowed with the WebSocket transport');
});

test('the call tells the assistant who is calling, from Tori', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push({ url, key: init.headers['x-tori-mcp-key'], body: JSON.parse(init.body) });
    if (url.endsWith('/api/agent/context')) return new Response(JSON.stringify({ text: 'Name: Asha (confirmed)' }), { status: 200 });
    return new Response(JSON.stringify({ id: 'vc1', transport: { websocketCallUrl: 'wss://x' } }), { status: 201 });
  };
  const vapi = vapiClient({ privateKey: 'PRIV', assistantId: 'a', contextUrl: 'http://web:3000/api/agent/context', contextKey: 'K', fetchImpl });
  await vapi.createCall({ metaCallId: 'wacid.A', waId: '919500000001', name: 'Asha' });
  assert.deepEqual(seen[0], { url: 'http://web:3000/api/agent/context', key: 'K', body: { wa_id: '919500000001' } });
  assert.equal(seen[1].body.assistantOverrides.variableValues.tori_caller, 'Name: Asha (confirmed)');

  const down = vapiClient({ privateKey: 'PRIV', assistantId: 'a', contextUrl: 'http://web:3000/api/agent/context', contextKey: 'K',
    fetchImpl: async (url, init) => (url.endsWith('/context') ? Promise.reject(new Error('down'))
      : (seen.push({ body: JSON.parse(init.body) }), new Response(JSON.stringify({ id: 'vc2', transport: { websocketCallUrl: 'wss://x' } }), { status: 201 }))) });
  await down.createCall({ metaCallId: 'wacid.B', waId: '919500000002', name: 'Bina' });
  assert.match(seen.at(-1).body.assistantOverrides.variableValues.tori_caller, /Bina\. Tori's details didn't load: use get_my_status/,
               'Tori unreachable: the call still starts');
});

test('Vapi refusals are errors', async () => {
  const vapi = vapiClient({ privateKey: 'bad', assistantId: 'a', fetchImpl: async () => new Response('{"message":"Invalid Key"}', { status: 401 }) });
  await assert.rejects(vapi.createCall({ metaCallId: 'x' }), /\(401\): Invalid Key/);
});

test('registry: duplicates, the concurrency limit, and memory of ended calls', () => {
  let now = 0;
  const reg = new Registry({ maxCalls: 2, rememberMs: 1000, now: () => now });
  const { EventEmitter } = require('node:events');
  const session = (id) => Object.assign(new EventEmitter(), { id });
  const a = session('A'), b = session('B');
  assert.equal(reg.admit('A'), 'ok'); reg.add(a);
  assert.equal(reg.admit('A'), 'duplicate');
  assert.equal(reg.admit('B'), 'ok'); reg.add(b);
  assert.equal(reg.admit('C'), 'busy');
  a.emit('end');
  assert.equal(reg.size, 1);
  assert.equal(reg.admit('A'), 'duplicate', 'a retried webhook for an ended call');
  assert.equal(reg.admit('C'), 'ok', 'a slot is free again');
  now = 5000;
  assert.equal(reg.admit('A'), 'ok', 'forgotten after rememberMs');
});

test('config: repo names and setup-guide names both work; missing secrets are listed', () => {
  const { cfg, missing } = loadConfig({ BOT_WHATSAPP_TOKEN: 't', META_PHONE_NUMBER_ID: '1', VAPI_PRIVATE_API_KEY: 'k', VOICE_BRIDGE_SECRET: 's' });
  assert.deepEqual(missing, []);
  assert.equal(cfg.meta.token, 't');
  assert.equal(cfg.meta.phoneNumberId, '1');
  assert.deepEqual(cfg.session.iceServers, [{ urls: 'stun:stun.l.google.com:19302' }]);
  assert.equal(loadConfig({}).missing.length, 4);
});
