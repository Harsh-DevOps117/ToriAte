'use strict';
const http = require('http');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8090);

let state;
function reset() {
  state = {
    tokens: new Set(),
    tokenRequests: 0,
    calendars: {},
    calendarCalls: [],
    whatsapp: [],
    llm: { requests: 0, last: null },
    faults: { calendar_fail_next: 0, whatsapp_fail_next: 0, llm_fail_next: 0 },
  };
}
reset();

function send(res, status, body, headers = {}) {
  if (status === 204) {
    res.writeHead(204, headers);
    return res.end();
  }
  const isString = typeof body === 'string';
  res.writeHead(status, {
    'content-type': isString ? 'text/html; charset=utf-8' : 'application/json',
    ...headers,
  });
  res.end(isString ? body : JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

function parseJson(raw) {
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    return undefined;
  }
}

function b64urlJson(part) {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

function bearer(req) {
  const h = req.headers.authorization || '';
  return h.startsWith('Bearer ') ? h.slice(7) : null;
}

const googleError = (code, message) => ({ error: { code, message, errors: [{ message, reason: String(code) }] } });

function googleToken(req, res, raw) {
  const form = new URLSearchParams(raw);
  if (form.get('grant_type') !== 'urn:ietf:params:oauth:grant-type:jwt-bearer') {
    return send(res, 400, { error: 'unsupported_grant_type' });
  }
  const parts = (form.get('assertion') || '').split('.');
  if (parts.length !== 3) return send(res, 400, { error: 'invalid_grant', error_description: 'bad JWT' });
  let header, claims;
  try {
    header = b64urlJson(parts[0]);
    claims = b64urlJson(parts[1]);
  } catch {
    return send(res, 400, { error: 'invalid_grant', error_description: 'undecodable JWT' });
  }
  const now = Math.floor(Date.now() / 1000);
  if (header.alg !== 'RS256') return send(res, 400, { error: 'invalid_grant', error_description: 'alg must be RS256' });
  if (!claims.iss || !String(claims.scope || '').includes('calendar')) {
    return send(res, 400, { error: 'invalid_scope' });
  }
  if (!(claims.exp > now) || claims.exp - claims.iat > 3600) {
    return send(res, 400, { error: 'invalid_grant', error_description: 'bad exp/iat' });
  }
  state.tokenRequests++;
  const token = 'ya29.mock-' + crypto.randomBytes(12).toString('hex');
  state.tokens.add(token);
  send(res, 200, { access_token: token, expires_in: 3599, token_type: 'Bearer' });
}

async function googleCalendar(req, res, path, raw) {
  const m = path.match(/^\/google\/calendar\/v3\/calendars\/([^/]+)\/events(?:\/([^/?]+))?$/);
  if (!m) return send(res, 404, googleError(404, 'Not Found'));
  const calendarId = decodeURIComponent(m[1]);
  const eventId = m[2] ? decodeURIComponent(m[2]) : null;
  state.calendarCalls.push({ at: new Date().toISOString(), method: req.method, calendarId, eventId });

  if (!state.tokens.has(bearer(req))) return send(res, 401, googleError(401, 'Invalid Credentials'));
  if (state.faults.calendar_fail_next > 0) {
    state.faults.calendar_fail_next--;
    return send(res, 503, googleError(503, 'Backend Error (injected)'));
  }
  if (calendarId.includes('missing')) return send(res, 404, googleError(404, 'Not Found'));
  if (calendarId.includes('forbidden')) {
    return send(res, 403, googleError(403, 'You need to have writer access to this calendar.'));
  }

  const cal = (state.calendars[calendarId] ||= new Map());
  const stamp = new Date().toISOString();
  const withMeta = (ev, existing) => ({
    ...ev,
    kind: 'calendar#event',
    status: ev.status || 'confirmed',
    htmlLink: `https://calendar.google.com/calendar/event?eid=${Buffer.from(ev.id + ' ' + calendarId).toString('base64url')}`,
    iCalUID: `${ev.id}@google.com`,
    created: existing?.created || stamp,
    updated: stamp,
  });

  if (req.method === 'POST' && !eventId) {
    const ev = parseJson(raw);
    if (!ev) return send(res, 400, googleError(400, 'Parse Error'));
    ev.id ||= crypto.randomBytes(10).toString('hex');
    if (!/^[a-v0-9]{5,1024}$/.test(ev.id)) return send(res, 400, googleError(400, 'Invalid resource id value.'));
    if (!ev.start || !ev.end) return send(res, 400, googleError(400, 'Missing end time.'));
    if (cal.has(ev.id)) return send(res, 409, googleError(409, 'The requested identifier already exists.'));
    const stored = withMeta(ev);
    cal.set(ev.id, stored);
    return send(res, 200, stored);
  }
  if (req.method === 'PUT' && eventId) {
    const ev = parseJson(raw);
    if (!ev) return send(res, 400, googleError(400, 'Parse Error'));
    if (!cal.has(eventId)) return send(res, 404, googleError(404, 'Not Found'));
    const stored = withMeta({ ...ev, id: eventId }, cal.get(eventId));
    cal.set(eventId, stored);
    return send(res, 200, stored);
  }
  if (req.method === 'DELETE' && eventId) {
    const ev = cal.get(eventId);
    if (!ev) return send(res, 404, googleError(404, 'Not Found'));
    if (ev.status === 'cancelled') return send(res, 410, googleError(410, 'Resource has been deleted'));
    ev.status = 'cancelled';
    ev.updated = stamp;
    return send(res, 204);
  }
  if (req.method === 'GET' && eventId) {
    return cal.has(eventId) ? send(res, 200, cal.get(eventId)) : send(res, 404, googleError(404, 'Not Found'));
  }
  if (req.method === 'GET') {
    return send(res, 200, { kind: 'calendar#events', items: [...cal.values()].filter((e) => e.status !== 'cancelled') });
  }
  send(res, 405, googleError(405, 'Method not allowed'));
}

function whatsapp(req, res, path, raw) {
  const m = path.match(/^\/whatsapp\/(v[\d.]+)\/(\d+)\/messages$/);
  if (!m || req.method !== 'POST') return send(res, 404, { error: { message: 'Unknown path', code: 100 } });
  if (!bearer(req)) {
    return send(res, 401, { error: { message: 'Invalid OAuth access token.', type: 'OAuthException', code: 190 } });
  }
  const body = parseJson(raw);
  if (!body || body.messaging_product !== 'whatsapp' || !/^\d{8,15}$/.test(String(body.to || ''))) {
    return send(res, 400, { error: { message: '(#100) Invalid parameter', type: 'OAuthException', code: 100 } });
  }
  if (state.faults.whatsapp_fail_next > 0) {
    state.faults.whatsapp_fail_next--;
    return send(res, 500, { error: { message: 'Service temporarily unavailable (injected)', code: 131000 } });
  }
  if (String(body.to).endsWith('000000')) {
    return send(res, 400, { error: { message: 'Recipient phone number not in allowed list', code: 131030 } });
  }
  let text;
  if (body.type === 'text' && typeof body.text?.body === 'string') {
    text = body.text.body;
  } else if (body.type === 'template' && body.template?.name && body.template?.language?.code) {
    const params = (body.template.components || []).flatMap((c) => c.parameters || []).map((p) => p.text);
    if (params.some((p) => /[\n\t]| {5,}/.test(p))) {
      return send(res, 400, { error: { message: 'Param text cannot have new-line/tab characters', code: 132018 } });
    }
    text = `[template ${body.template.name}] ` + params.join(' | ');
  } else {
    return send(res, 400, { error: { message: '(#100) Invalid parameter: type', code: 100 } });
  }
  const id = 'wamid.MOCK' + crypto.randomBytes(8).toString('hex').toUpperCase();
  state.whatsapp.push({ id, at: new Date().toISOString(), phoneNumberId: m[2], to: body.to, type: body.type, text });
  send(res, 200, { messaging_product: 'whatsapp', contacts: [{ input: body.to, wa_id: body.to }], messages: [{ id }] });
}

const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };

function to24h(t) {
  const m = String(t).trim().match(/^(\d{1,2}):(\d{2})\s*([AaPp][Mm])?$/);
  if (!m) return null;
  let h = Number(m[1]);
  const ap = (m[3] || '').toLowerCase();
  if (ap === 'pm' && h < 12) h += 12;
  if (ap === 'am' && h === 12) h = 0;
  return `${String(h).padStart(2, '0')}:${m[2]}`;
}

function toIsoDate(d) {
  const m = String(d).match(/(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})/);
  if (!m) return null;
  const mon = MONTHS[m[2].toLowerCase()];
  return mon ? `${m[3]}-${String(mon).padStart(2, '0')}-${m[1].padStart(2, '0')}` : null;
}

function mockParse(subject, body) {
  const all = `${subject}\n${body}`;
  const get = (re) => (all.match(re) || [])[1]?.trim() || null;
  const lower = all.toLowerCase();
  let email_type = 'not_a_booking';
  if (/cancel/.test(lower)) email_type = 'booking_cancelled';
  else if (/reschedul|modified/.test(lower)) email_type = 'booking_modified';
  else if (/booking confirmed|new booking/.test(lower)) email_type = 'booking_confirmed';

  const slots = [];
  const re = /Court:\s*(.+)\r?\n\s*Date:\s*(.+)\r?\n\s*Time:\s*(.+)/g;
  let m;
  while ((m = re.exec(body))) {
    const [start, end] = m[3].split(/\s*[-–]\s*/);
    slots.push({ court: m[1].trim(), date: toIsoDate(m[2]), start_time: to24h(start), end_time: to24h(end) });
  }
  const amount = get(/Amount[^:\n]*:\s*₹?\s*([\d,]+(?:\.\d+)?)/i);
  const pay = (get(/Payment(?: Status)?:\s*([A-Za-z ]+)/i) || '').toLowerCase();
  return {
    email_type,
    playo_booking_id: get(/Booking ID:\s*([A-Z0-9-]+)/i),
    customer_name: get(/Customer(?: Name)?:\s*(.+)/i),
    customer_phone: get(/Phone:\s*(.+)/i),
    amount: amount ? Number(amount.replace(/,/g, '')) : null,
    payment_status: /partial/.test(pay) ? 'partially_paid' : /unpaid|pay at venue/.test(pay) ? 'unpaid' : /paid/.test(pay) ? 'paid' : 'unknown',
    sport: get(/Sport:\s*(.+)/i),
    slots: slots.filter((s) => s.date && s.start_time && s.end_time),
    confidence: slots.length ? 'high' : 'low',
    notes: null,
  };
}

function groq(req, res, path, raw) {
  const groqError = (status, type, message) => send(res, status, { error: { message, type } });
  if (path !== '/groq/openai/v1/chat/completions' || req.method !== 'POST') {
    return groqError(404, 'invalid_request_error', 'Unknown request URL');
  }
  if (!/^Bearer \S+/.test(req.headers.authorization || '')) return groqError(401, 'invalid_request_error', 'Invalid API Key');
  const body = parseJson(raw);
  if (!body || !body.model || !Array.isArray(body.messages)) {
    return groqError(400, 'invalid_request_error', 'model and messages are required');
  }
  if (body.response_format?.type !== 'json_schema' || !body.response_format?.json_schema?.schema) {
    return groqError(400, 'invalid_request_error', 'expected response_format json_schema');
  }
  state.llm.requests++;
  if (state.faults.llm_fail_next > 0) {
    state.faults.llm_fail_next--;
    return groqError(503, 'service_unavailable', 'Service Unavailable (injected)');
  }
  const userText = body.messages.filter((m) => m.role === 'user').map((m) => m.content).join('\n');
  const subject = (userText.match(/<subject>([\s\S]*?)<\/subject>/) || [])[1] || '';
  const emailBody = (userText.match(/<body>([\s\S]*?)<\/body>/) || [])[1] || '';
  const result = mockParse(subject, emailBody);
  state.llm.last = { at: new Date().toISOString(), model: body.model, subject: subject.trim(), result };
  send(res, 200, {
    id: 'chatcmpl-mock-' + crypto.randomBytes(8).toString('hex'),
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: body.model,
    choices: [{ index: 0, message: { role: 'assistant', content: JSON.stringify(result) }, finish_reason: 'stop' }],
    usage: { prompt_tokens: Math.ceil(userText.length / 4), completion_tokens: 120, total_tokens: Math.ceil(userText.length / 4) + 120 },
  });
}

function snapshot() {
  const calendars = {};
  for (const [id, events] of Object.entries(state.calendars)) {
    calendars[id] = [...events.values()].sort((a, b) =>
      String(a.start?.dateTime || a.start?.date).localeCompare(String(b.start?.dateTime || b.start?.date)));
  }
  return {
    calendars,
    calendarCalls: state.calendarCalls.length,
    whatsapp: state.whatsapp,
    llm: state.llm,
    tokenRequests: state.tokenRequests,
    faults: state.faults,
  };
}

const DASHBOARD = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tori mock APIs</title><style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2433;--muted:#667085;--line:#e4e7ec;--ok:#0f766e;--warn:#b54708;--bad:#b42318;--bubble:#dcf8c6}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--ink:#e6e8ec;--muted:#98a2b3;--line:#2a2f3a;--ok:#2dd4bf;--warn:#fdb022;--bad:#f97066;--bubble:#1f3b2c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,sans-serif}
header{padding:16px;border-bottom:1px solid var(--line)}h1{font-size:18px;margin:0}header p{margin:4px 0 0;color:var(--muted)}
main{display:grid;grid-template-columns:1fr 1fr;gap:16px;padding:16px}@media (max-width:800px){main{grid-template-columns:1fr}}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;min-width:0}h2{font-size:15px;margin:0 0 8px}
h3{font-size:13px;color:var(--muted);margin:12px 0 6px;word-break:break-all}.ev{border-left:4px solid var(--ok);padding:6px 8px;margin:6px 0;background:var(--bg);border-radius:6px}
.ev.clash{border-color:var(--bad)}.ev.check{border-color:var(--warn)}.ev.cancelled{opacity:.45;text-decoration:line-through}
.t{color:var(--muted);font-size:12px}.msg{background:var(--bubble);border-radius:8px;padding:8px;margin:6px 0;white-space:pre-wrap;word-break:break-word}
.empty{color:var(--muted)}</style></head><body>
<header><h1>Tori mock APIs</h1><p>What n8n sent to "Google Calendar" and "WhatsApp". Refreshes every 3 s. Raw JSON: <a href="/_state">/_state</a></p></header>
<main><section><h2>Google Calendar</h2><div id="cal"></div></section><section><h2>WhatsApp</h2><div id="wa"></div></section></main>
<script>
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function load(){const s=await (await fetch('/_state')).json();
let h='';for(const [id,evs] of Object.entries(s.calendars)){h+='<h3>'+esc(id)+'</h3>';for(const e of evs){
const cls=e.status==='cancelled'?'cancelled':/CLASH/.test(e.summary)?'clash':/CHECK|Check/.test(e.summary)?'check':'';
const when=e.start.dateTime?e.start.dateTime.replace('T',' ').slice(0,16)+'–'+e.end.dateTime.slice(11,16):e.start.date+' (all day)';
h+='<div class="ev '+cls+'"><b>'+esc(e.summary)+'</b><div class="t">'+esc(when)+' · '+esc(e.status)+'</div></div>';}}
document.getElementById('cal').innerHTML=h||'<p class="empty">No events yet.</p>';
let w='';const by={};for(const m of s.whatsapp){(by[m.to]??=[]).push(m)}
for(const [to,ms] of Object.entries(by)){w+='<h3>+'+esc(to)+'</h3>';for(const m of ms){w+='<div class="msg">'+esc(m.text)+'<div class="t">'+esc(m.at.slice(11,19))+'</div></div>'}}
document.getElementById('wa').innerHTML=w||'<p class="empty">No messages yet.</p>';}
load();setInterval(load,3000);
</script></body></html>`;

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const path = url.pathname;
  const raw = await readBody(req);
  try {
    if (path === '/health') return send(res, 200, { ok: true });
    if (path === '/') return send(res, 200, DASHBOARD);
    if (path === '/_state') return send(res, 200, snapshot());
    if (path === '/_reset' && req.method === 'POST') {
      reset();
      return send(res, 200, { ok: true });
    }
    if (path === '/_faults' && req.method === 'POST') {
      Object.assign(state.faults, parseJson(raw) || {});
      return send(res, 200, state.faults);
    }
    if (path === '/google/token' && req.method === 'POST') return googleToken(req, res, raw);
    if (path.startsWith('/google/calendar/v3/')) return googleCalendar(req, res, path, raw);
    if (path.startsWith('/whatsapp/')) return whatsapp(req, res, path, raw);
    if (path.startsWith('/groq/')) return groq(req, res, path, raw);
    send(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: String(err) });
  }
}).listen(PORT, () => console.log(`mock-apis listening on :${PORT}`));
