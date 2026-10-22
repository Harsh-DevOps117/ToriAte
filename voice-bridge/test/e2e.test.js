'use strict';
// The whole bridge with real WebRTC (libwebrtc, Opus, ICE, DTLS-SRTP over localhost) and fake Meta + Vapi
// servers. Each fake WhatsApp caller speaks its own tone and each fake Vapi session answers with its own
// tone, so the frequencies show whether audio reached the right place, both ways, and never crossed over.
//
//   caller A: says 1000 Hz, Vapi A answers 440 Hz      caller B: says 1500 Hz, Vapi B answers 660 Hz
//   caller C: arrives while A and B are on (max 2 calls) → rejected as busy

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const wrtc = require('@roamhq/wrtc');
const WebSocket = require('ws');
const { createBridge } = require('../src/bridge');
const { metaCalls } = require('../src/meta');
const { vapiClient } = require('../src/vapi');
const { waitIceGathering } = require('../src/session');
const { tone, power } = require('./helpers');

const { RTCPeerConnection, nonstandard: { RTCAudioSource, RTCAudioSink } } = wrtc;
const SECRET = 'test-secret';
const PHONE_ID = '1330443963491296';

const listen = (server) => new Promise((r) => server.listen(0, '127.0.0.1', () => r(server.address().port)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, ms, what) {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error(`timed out waiting for ${what}`);
    await sleep(20);
  }
}
const concat = (chunks) => {
  const out = new Int16Array(chunks.reduce((n, c) => n + c.length, 0));
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
};
const readJson = async (req) => { let b = ''; for await (const c of req) b += c; return b ? JSON.parse(b) : {}; };

// A WhatsApp user's phone, as Meta's media server would look to the bridge: makes the SDP offer, sends a tone.
async function makeCaller(id, freq) {
  const pc = new RTCPeerConnection();
  const src = new RTCAudioSource();
  pc.addTrack(src.createTrack());
  const caller = { id, pc, heard: [], sink: null };
  pc.ontrack = (e) => {
    caller.sink = new RTCAudioSink(e.track);
    caller.sink.ondata = (d) => caller.heard.push(Int16Array.from(d.samples));
  };
  await pc.setLocalDescription(await pc.createOffer());
  await waitIceGathering(pc, 3000);
  caller.offer = pc.localDescription.sdp;
  let phase = 0;
  caller.timer = setInterval(() => {
    src.onData({ samples: tone(freq, 48000, 0.01, 8000, phase), sampleRate: 48000, bitsPerSample: 16, channelCount: 1, numberOfFrames: 480 });
    phase += 480;
  }, 10);
  caller.close = () => { clearInterval(caller.timer); try { caller.sink?.stop(); } catch {} pc.close(); };
  return caller;
}

const connectItem = (caller, name) => ({
  field: 'calls', messaging_product: 'whatsapp', metadata: { phone_number_id: PHONE_ID },
  contacts: [{ profile: { name }, wa_id: `91950000000${name.length}` }],
  calls: [{ id: caller.id, from: `91950000000${name.length}`, event: 'connect', direction: 'USER_INITIATED',
            timestamp: '1792540000', session: { sdp_type: 'offer', sdp: caller.offer } }],
});

test('two WhatsApp calls at once: bidirectional audio, isolation, busy, hang-ups from either side', { timeout: 60000 }, async (t) => {
  const callers = new Map();
  const cleanups = [];
  t.after(async () => { for (const f of cleanups.reverse()) await f(); });

  // ── fake Meta Graph API: call control ──
  const metaRequests = [];
  const meta = http.createServer(async (req, res) => {
    const b = await readJson(req);
    metaRequests.push({ path: req.url, auth: req.headers.authorization, ...b });
    const caller = callers.get(b.call_id);
    // the answer reaches the phone with pre_accept; media can start flowing before accept
    if (b.action === 'pre_accept' && caller) await caller.pc.setRemoteDescription({ type: 'answer', sdp: b.session.sdp });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"messaging_product":"whatsapp","success":true}');
  });
  const metaPort = await listen(meta);
  cleanups.push(() => new Promise((r) => meta.close(r)));

  // ── fake Vapi: POST /call + the WebSocket transport ──
  const vapiCalls = new Map(); // vapi id → { body, ws, received, control, closed }
  const ANSWER_TONE = { 'wacid.A': 440, 'wacid.B': 660 };
  const vapiHttp = http.createServer(async (req, res) => {
    const body = await readJson(req);
    const id = `vapi-${body.assistantOverrides.metadata.metaCallId}`;
    vapiCalls.set(id, { body, received: [], control: [], closed: false });
    res.writeHead(201, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ id, type: 'vapi.websocketCall', transport: { provider: 'vapi.websocket', websocketCallUrl: `ws://127.0.0.1:${vapiPort}/${id}/transport` } }));
  });
  const wss = new WebSocket.Server({ server: vapiHttp });
  wss.on('connection', (ws, req) => {
    const id = req.url.split('/')[1];
    const call = vapiCalls.get(id);
    call.ws = ws;
    ws.on('message', (data, isBinary) => {
      if (isBinary) call.received.push(new Int16Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.length)));
      else call.control.push(JSON.parse(data.toString()));
    });
    ws.on('close', () => { call.closed = true; });
    // the assistant's greeting: 1.5 s of its tone, sent in one burst like a TTS engine would
    const speech = tone(ANSWER_TONE[call.body.assistantOverrides.metadata.metaCallId], 16000, 1.5, 8000);
    for (let i = 0; i < speech.length; i += 1600) ws.send(Buffer.from(speech.slice(i, i + 1600).buffer));
  });
  const vapiPort = await listen(vapiHttp);
  cleanups.push(() => new Promise((r) => { for (const c of wss.clients) c.terminate(); wss.close(); vapiHttp.close(r); }));

  // ── fake n8n: lifecycle events ──
  const events = [];
  const n8n = http.createServer(async (req, res) => {
    events.push({ secret: req.headers['x-bridge-secret'], ...(await readJson(req)) });
    res.writeHead(200); res.end();
  });
  const n8nPort = await listen(n8n);
  cleanups.push(() => new Promise((r) => n8n.close(r)));

  // ── the bridge ──
  const logs = [];
  const cfg = {
    secret: SECRET, maxCalls: 2, eventsUrl: `http://127.0.0.1:${n8nPort}/webhook/voice/events`,
    meta: { phoneNumberId: PHONE_ID }, vapi: { sampleRate: 16000 },
    session: { iceServers: [], maxCallSeconds: 60, setupTimeoutMs: 15000 },
  };
  const bridge = createBridge(cfg, {
    rtc: { RTCPeerConnection, RTCAudioSource, RTCAudioSink },
    meta: metaCalls({ graphUrl: `http://127.0.0.1:${metaPort}`, phoneNumberId: PHONE_ID, token: 'META_TOKEN' }),
    vapi: vapiClient({ apiUrl: `http://127.0.0.1:${vapiPort}`, privateKey: 'VAPI_PRIVATE', assistantId: 'afd96ebf-40a7-40d2-bc0b-b6b94367e588' }),
    WebSocket,
    log: (level, msg, f) => logs.push({ level, msg, ...f }),
  });
  const bridgePort = await listen(bridge.server);
  cleanups.push(() => bridge.shutdown());
  t.after(() => { if (process.exitCode) console.log(logs); });

  const post = (body, secret = SECRET) => fetch(`http://127.0.0.1:${bridgePort}/calls/event`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-bridge-secret': secret }, body: JSON.stringify(body),
  });

  // ── two callers ring at the same time ──
  const [a, b, c] = await Promise.all([makeCaller('wacid.A', 1000), makeCaller('wacid.B', 1500), makeCaller('wacid.C', 1200)]);
  for (const x of [a, b, c]) { callers.set(x.id, x); cleanups.push(() => x.close()); }

  assert.equal((await post(connectItem(a, 'A'), 'wrong')).status, 401, 'n8n must send the shared secret');
  const [ra, rb] = await Promise.all([post(connectItem(a, 'Asha')), post(connectItem(b, 'Bilal'))]);
  assert.deepEqual((await ra.json()).handled, [{ id: 'wacid.A', event: 'connect', result: 'answering' }]);
  assert.deepEqual((await rb.json()).handled, [{ id: 'wacid.B', event: 'connect', result: 'answering' }]);
  assert.equal((await (await post(connectItem(a, 'Asha'))).json()).handled[0].result, 'duplicate', 'Meta retried the webhook');
  assert.equal((await (await post(connectItem(c, 'Chen'))).json()).handled[0].result, 'rejected_busy');

  const actions = (id) => metaRequests.filter((r) => r.call_id === id).map((r) => r.action);
  await until(() => actions('wacid.A').includes('accept') && actions('wacid.B').includes('accept'), 15000, 'both calls accepted');
  await until(() => actions('wacid.C').includes('reject'), 3000, 'busy call rejected');

  // Meta protocol: pre_accept then accept, the same SDP answer, our token, the right endpoint
  for (const id of ['wacid.A', 'wacid.B']) {
    const reqs = metaRequests.filter((r) => r.call_id === id);
    assert.deepEqual(reqs.map((r) => r.action), ['pre_accept', 'accept']);
    assert.equal(reqs[0].session.sdp, reqs[1].session.sdp, 'accept carries the pre_accept SDP');
    assert.match(reqs[0].session.sdp, /a=rtpmap:\d+ opus\/48000\/2/);
    assert.equal(reqs[0].path, `/${PHONE_ID}/calls`);
    assert.equal(reqs[0].auth, 'Bearer META_TOKEN');
  }
  assert.equal(vapiCalls.size, 2, 'one Vapi session per WhatsApp call, none for the busy one');
  assert.equal(vapiCalls.get('vapi-wacid.A').body.transport.audioFormat.sampleRate, 16000);

  // ── audio both ways ──
  const vA = vapiCalls.get('vapi-wacid.A'), vB = vapiCalls.get('vapi-wacid.B');
  const secondsIn = (chunks, rate) => chunks.reduce((n, x) => n + x.length, 0) / rate;
  await until(() => secondsIn(vA.received, 16000) > 1 && secondsIn(vB.received, 16000) > 1, 10000, 'caller audio at Vapi');
  await until(() => secondsIn(a.heard, 48000) > 1.6 && secondsIn(b.heard, 48000) > 1.6, 10000, 'assistant audio at the callers');

  const toVapiA = concat(vA.received).slice(1600), toVapiB = concat(vB.received).slice(1600);
  assert.ok(power(toVapiA, 1000, 16000) > 20 * power(toVapiA, 1500, 16000), 'Vapi A hears caller A (1000 Hz), not B');
  assert.ok(power(toVapiB, 1500, 16000) > 20 * power(toVapiB, 1000, 16000), 'Vapi B hears caller B (1500 Hz), not A');
  const heardA = concat(a.heard), heardB = concat(b.heard);
  assert.ok(power(heardA, 440, 48000) > 20 * power(heardA, 660, 48000), 'caller A hears assistant A (440 Hz), not B');
  assert.ok(power(heardB, 660, 48000) > 20 * power(heardB, 440, 48000), 'caller B hears assistant B (660 Hz), not A');
  assert.ok(power(heardA, 440, 48000) > 1000, 'the assistant is actually audible');

  const list = await (await fetch(`http://127.0.0.1:${bridgePort}/calls`, { headers: { 'x-bridge-secret': SECRET } })).json();
  assert.deepEqual(list.active.map((s) => [s.meta_call_id, s.state, s.media]).sort(), [['wacid.A', 'active', 'connected'], ['wacid.B', 'active', 'connected']]);

  // ── caller A hangs up: Meta's terminate webhook ends the Vapi session, B carries on ──
  const rt = await post({ field: 'calls', calls: [{ id: 'wacid.A', event: 'terminate', status: 'COMPLETED', duration: 3 }] });
  assert.equal((await rt.json()).handled[0].result, 'ended');
  await until(() => vA.closed, 3000, 'Vapi A socket closed');
  assert.deepEqual(vA.control.at(-1), { type: 'end-call' });
  assert.ok(!actions('wacid.A').includes('terminate'), 'no terminate for a call Meta already ended');
  assert.equal(bridge.registry.size, 1);
  assert.ok(!vB.closed, 'B is untouched');

  // ── the assistant ends B (Vapi closes the socket): the bridge terminates the WhatsApp call ──
  vB.ws.close(1000);
  await until(() => actions('wacid.B').includes('terminate'), 3000, 'Meta terminate for B');
  await until(() => bridge.registry.size === 0, 3000, 'no active calls');

  // a retried connect for a finished call does nothing
  assert.equal((await (await post(connectItem(a, 'Asha'))).json()).handled[0].result, 'duplicate');

  // ── lifecycle reported to n8n ──
  await sleep(200);
  const seq = (id) => events.filter((e) => e.meta_call_id === id).map((e) => e.event);
  assert.deepEqual(seq('wacid.A'), ['ringing', 'connecting', 'active', 'ended']);
  assert.deepEqual(seq('wacid.B'), ['ringing', 'connecting', 'active', 'ended']);
  assert.deepEqual(seq('wacid.C'), ['rejected']);
  assert.equal(events.find((e) => e.meta_call_id === 'wacid.A' && e.event === 'ended').reason, 'caller_hung_up');
  assert.equal(events.find((e) => e.meta_call_id === 'wacid.B' && e.event === 'ended').reason, 'assistant_ended');
  assert.equal(events.find((e) => e.meta_call_id === 'wacid.C').reason, 'busy');
  assert.equal(events.find((e) => e.event === 'active' && e.meta_call_id === 'wacid.A').vapi_call_id, 'vapi-wacid.A');
  assert.ok(events.every((e) => e.secret === SECRET));
});

test('a Vapi failure rejects the WhatsApp call instead of leaving it ringing', { timeout: 30000 }, async (t) => {
  const metaRequests = [];
  const meta = http.createServer(async (req, res) => { metaRequests.push(await readJson(req)); res.writeHead(200); res.end('{"success":true}'); });
  const metaPort = await listen(meta);
  const vapi = http.createServer((req, res) => { res.writeHead(401, { 'content-type': 'application/json' }); res.end('{"message":"Invalid Key. Hot tip, you may be using the private key instead of the public key, or vice versa."}'); });
  const vapiPort = await listen(vapi);
  const logs = [];
  const bridge = createBridge({ secret: SECRET, maxCalls: 2, meta: { phoneNumberId: PHONE_ID }, vapi: { sampleRate: 16000 }, session: { iceServers: [] } }, {
    rtc: { RTCPeerConnection, RTCAudioSource, RTCAudioSink },
    meta: metaCalls({ graphUrl: `http://127.0.0.1:${metaPort}`, phoneNumberId: PHONE_ID, token: 'T' }),
    vapi: vapiClient({ apiUrl: `http://127.0.0.1:${vapiPort}`, privateKey: 'bad', assistantId: 'x' }),
    WebSocket, log: (level, msg, f) => logs.push({ level, msg, ...f }),
  });
  const caller = await makeCaller('wacid.F', 1000);
  t.after(async () => { caller.close(); await bridge.shutdown(); meta.close(); vapi.close(); });
  bridge.handleBody(connectItem(caller, 'Farah'));
  await until(() => metaRequests.some((r) => r.action === 'reject'), 10000, 'reject');
  assert.deepEqual(metaRequests.map((r) => r.action), ['pre_accept', 'reject'], 'never accepted');
  assert.ok(logs.some((l) => l.msg === 'call setup failed' && /401/.test(l.error)));
  await until(() => bridge.registry.size === 0, 2000, 'session cleaned up');
});

test('the bridge refuses calls while it is not configured', async () => {
  const rejected = [];
  const bridge = createBridge({ secret: SECRET, maxCalls: 1, meta: {}, vapi: {}, session: {} }, {
    rtc: {}, vapi: {}, WebSocket, log: () => {},
    meta: { reject: async (id) => { rejected.push(id); } },
  }, ['VAPI_PRIVATE_API_KEY']);
  const out = bridge.handleBody({ field: 'calls', calls: [{ id: 'wacid.N', event: 'connect', session: { sdp_type: 'offer', sdp: 'v=0' } }] });
  assert.equal(out[0].result, 'rejected_not_configured');
  await sleep(10);
  assert.deepEqual(rejected, ['wacid.N']);
});
