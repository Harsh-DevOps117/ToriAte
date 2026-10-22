'use strict';
// HTTP side of the bridge: takes call webhooks (from n8n, or straight from Meta), starts and ends call
// sessions, and reports their lifecycle to n8n. Audio never passes through here or through n8n.
//
//   POST /calls/event    n8n forwards Meta's `calls` webhook (header X-Bridge-Secret)
//   GET|POST /meta/webhook  Meta directly (verify token / X-Hub-Signature-256), if you point a Meta app here
//   GET  /calls          active calls (X-Bridge-Secret)
//   GET  /health

const http = require('node:http');
const crypto = require('node:crypto');
const { callEvents } = require('./meta');
const { Registry } = require('./registry');
const { CallSession, mask } = require('./session');

const MAX_BODY = 1024 * 1024;

const safeEqual = (a, b) => {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
};

function validMetaSignature(raw, header, appSecret) {
  if (!appSecret || !header) return false;
  const expected = 'sha256=' + crypto.createHmac('sha256', appSecret).update(raw).digest('hex');
  return safeEqual(header, expected);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

/**
 * @param cfg   loadConfig().cfg
 * @param deps  { rtc, meta, vapi, WebSocket, log, fetchImpl? }
 * @param missing  config that is not set; calls are refused while anything is missing
 */
function createBridge(cfg, deps, missing = []) {
  const registry = new Registry({ maxCalls: cfg.maxCalls });
  const log = deps.log;

  // lifecycle → n8n (workflow 13), fire and forget: a slow n8n must never hold up a call
  const report = (ev) => {
    if (!cfg.eventsUrl) return;
    const fetchImpl = deps.fetchImpl || fetch;
    fetchImpl(cfg.eventsUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-bridge-secret': cfg.secret },
      body: JSON.stringify({ ...ev, at: new Date().toISOString() }),
      signal: AbortSignal.timeout(5000),
    }).then((r) => { if (!r.ok) log('warn', 'event report refused', { status: r.status, event: ev.event }); })
      .catch((err) => log('warn', 'event report failed', { error: err.message, event: ev.event }));
  };

  async function turnAway(call, reason) {
    registry.finish(call.id);
    report({ event: 'rejected', meta_call_id: call.id, wa_id: call.from, name: call.name, reason });
    try { await deps.meta.reject(call.id); } catch (err) { log('warn', 'reject failed', { call: call.id, error: err.message }); }
  }

  // one call event → what was done with it
  function handle(call) {
    if (!call.id) return 'no_call_id';
    if (cfg.meta.phoneNumberId && call.phoneNumberId && call.phoneNumberId !== cfg.meta.phoneNumberId) return 'other_number';
    if (call.event === 'connect') {
      if (call.direction && call.direction !== 'USER_INITIATED') return 'ignored_direction';
      const verdict = registry.admit(call.id);
      if (verdict === 'duplicate') return 'duplicate';
      log('info', 'incoming call', { call: call.id, from: mask(call.from) });
      if (missing.length) { turnAway(call, 'bridge_not_configured'); return 'rejected_not_configured'; }
      if (!call.sdp) { turnAway(call, 'no_sdp_offer'); return 'rejected_no_offer'; }
      if (verdict === 'busy') {
        log('warn', 'too many calls, rejecting', { call: call.id, active: registry.size, max: cfg.maxCalls });
        turnAway(call, 'busy');
        return 'rejected_busy';
      }
      const session = new CallSession(call, { ...deps, report }, { ...cfg.session, sampleRate: cfg.vapi.sampleRate });
      registry.add(session);
      report({ event: 'ringing', meta_call_id: call.id, wa_id: call.from, name: call.name });
      session.start();
      return 'answering';
    }
    if (call.event === 'terminate') {
      const session = registry.get(call.id);
      if (!session) return registry.wasHandled(call.id) ? 'already_ended' : 'unknown_call';
      const failed = String(call.status || '').toUpperCase() === 'FAILED';
      session.end(failed ? 'failed' : 'ended', failed ? (call.errors?.[0]?.message || 'meta_failed') : 'caller_hung_up', { remote: true });
      return 'ended';
    }
    return 'ignored';
  }

  const handleBody = (body) => callEvents(body).map((c) => ({ id: c.id, event: c.event, result: handle(c) }));

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://bridge');
    try {
      if (req.method === 'GET' && url.pathname === '/health') {
        return send(res, missing.length ? 503 : 200, { ok: !missing.length, active: registry.size, max: cfg.maxCalls, missing });
      }
      if (url.pathname === '/calls/event' && req.method === 'POST') {
        if (!safeEqual(req.headers['x-bridge-secret'], cfg.secret)) return send(res, 401, { error: 'unauthorized' });
        const raw = await readBody(req);
        return send(res, 200, { handled: handleBody(JSON.parse(raw.toString() || '{}')) });
      }
      if (url.pathname === '/calls' && req.method === 'GET') {
        if (!safeEqual(req.headers['x-bridge-secret'], cfg.secret)) return send(res, 401, { error: 'unauthorized' });
        return send(res, 200, { active: registry.list().map((s) => s.info()), max: cfg.maxCalls });
      }
      if (url.pathname === '/meta/webhook' && req.method === 'GET') {
        const ok = url.searchParams.get('hub.mode') === 'subscribe' && cfg.meta.verifyToken
          && safeEqual(url.searchParams.get('hub.verify_token'), cfg.meta.verifyToken);
        res.writeHead(ok ? 200 : 403, { 'content-type': 'text/plain' });
        return res.end(ok ? url.searchParams.get('hub.challenge') || '' : 'forbidden');
      }
      if (url.pathname === '/meta/webhook' && req.method === 'POST') {
        const raw = await readBody(req);
        if (!validMetaSignature(raw, req.headers['x-hub-signature-256'], cfg.meta.appSecret)) return send(res, 401, { error: 'bad signature' });
        return send(res, 200, { handled: handleBody(JSON.parse(raw.toString())) });
      }
      send(res, 404, { error: 'not found' });
    } catch (err) {
      log('error', 'request failed', { path: url.pathname, error: err.message });
      send(res, err.status || (err instanceof SyntaxError ? 400 : 500), { error: err.message });
    }
  });

  async function shutdown() {
    await Promise.all(registry.list().map((s) => s.end('ended', 'bridge_shutdown')));
    await new Promise((r) => server.close(r));
  }

  return { server, registry, handle, handleBody, shutdown };
}

module.exports = { createBridge, validMetaSignature };
