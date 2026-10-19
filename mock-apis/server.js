'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const pathLib = require('path');

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
    geocode: { requests: 0 },
    razorpay: { orders: {}, payments: {}, contacts: {}, fund_accounts: {}, payouts: {}, payout_keys: {} },
    media: { requests: 0 },
    payoutRequests: [],
    faults: { calendar_fail_next: 0, whatsapp_fail_next: 0, llm_fail_next: 0, geocode_fail_next: 0, payout_fail_next: 0 },
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

// Media a user "sent": GET /whatsapp/<version>/<media id> → { url, mime_type }, then GET that url (with the
// token) → the bytes. Media IDs starting with BIG answer 6 MB, GIF answer a GIF (both refused by the bot),
// VOICE answer a real spoken voice note (fixtures/voice-note.ogg, opus) for Whisper to transcribe;
// VOICEREQ a spoken partner request (fixtures/voice-request.ogg).
const TINY_JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64');
const mediaMime = (id) => (id.startsWith('GIF') ? 'image/gif' : id.startsWith('VOICE') ? 'audio/ogg; codecs=opus' : 'image/jpeg');
function whatsappMedia(req, res, path) {
  if (!bearer(req)) return send(res, 401, { error: { message: 'Invalid OAuth access token.', type: 'OAuthException', code: 190 } });
  const file = path.match(/^\/whatsapp\/media-file\/([\w.-]+)$/);
  if (file) {
    const id = file[1];
    const bytes = id.startsWith('BIG') ? Buffer.alloc(6 * 1024 * 1024, 1)
      : id.startsWith('VOICEREQ') ? fs.readFileSync(pathLib.join(__dirname, 'fixtures', 'voice-request.ogg'))
      : id.startsWith('VOICE') ? fs.readFileSync(pathLib.join(__dirname, 'fixtures', 'voice-note.ogg')) : TINY_JPEG;
    res.writeHead(200, { 'content-type': mediaMime(id), 'content-length': bytes.length });
    return res.end(bytes);
  }
  const id = path.split('/').pop();
  state.media.requests++;
  send(res, 200, { messaging_product: 'whatsapp', id, url: `http://mock-apis:8090/whatsapp/media-file/${id}`,
                   mime_type: mediaMime(id), file_size: id.startsWith('BIG') ? 6291456 : TINY_JPEG.length });
}

function whatsapp(req, res, path, raw) {
  if (req.method === 'GET' && (/^\/whatsapp\/media-file\//.test(path) || /^\/whatsapp\/v[\d.]+\/[\w.-]+$/.test(path))) {
    return whatsappMedia(req, res, path);
  }
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
  } else if (body.type === 'image' && /^https:\/\//.test(body.image?.link || '')) {
    text = (body.image.caption || '') + `\n[image ${body.image.link}]`;
  } else if (body.type === 'template' && body.template?.name && body.template?.language?.code) {
    const params = (body.template.components || []).flatMap((c) => c.parameters || []).map((p) => p.text);
    if (params.some((p) => /[\n\t]| {5,}/.test(p))) {
      return send(res, 400, { error: { message: 'Param text cannot have new-line/tab characters', code: 132018 } });
    }
    text = `[template ${body.template.name}] ` + params.join(' | ');
  } else if (body.type === 'interactive' && body.interactive?.type === 'button') {
    const buttons = body.interactive.action?.buttons || [];
    const body_ = body.interactive.body?.text || '';
    const header = body.interactive.header;
    if (!buttons.length || buttons.length > 3 || body_.length > 1024
        || buttons.some((b) => !b.reply?.id || !b.reply?.title || b.reply.title.length > 20)
        || (header && !(header.type === 'image' && /^https:\/\//.test(header.image?.link || '')))) {
      return send(res, 400, { error: { message: '(#131009) Parameter value is not valid', code: 131009 } });
    }
    text = body_ + '\n' + buttons.map((b) => `[${b.reply.title}]`).join(' ');
  } else if (body.type === 'interactive' && body.interactive?.type === 'list') {
    const sections = body.interactive.action?.sections || [];
    const rows = sections.flatMap((x) => x.rows || []);
    if (!rows.length || rows.length > 10 || (body.interactive.action?.button || '').length > 20
        || sections.some((x) => (x.title || '').length > 24)
        || rows.some((r) => !r.id || [...(r.title || '')].length > 24 || [...(r.description || '')].length > 72)) {
      return send(res, 400, { error: { message: '(#131009) Parameter value is not valid (list limits)', code: 131009 } });
    }
    text = (body.interactive.body?.text || '') + '\n' + sections.map((x) => `${x.title}: ` + x.rows.map((r) => r.title).join(', ')).join('\n');
  } else if (body.type === 'interactive' && body.interactive?.type === 'flow') {
    const fp = body.interactive.action?.parameters || {};
    if (body.interactive.action?.name !== 'flow' || !fp.flow_id || !fp.flow_cta || !fp.flow_token || fp.flow_message_version !== '3') {
      return send(res, 400, { error: { message: '(#100) Invalid flow parameters', code: 100 } });
    }
    text = (body.interactive.body?.text || '') + `\n[form: ${fp.flow_cta}]`;
  } else {
    return send(res, 400, { error: { message: '(#100) Invalid parameter: type', code: 100 } });
  }
  const id = 'wamid.MOCK' + crypto.randomBytes(8).toString('hex').toUpperCase();
  // buttons: reply IDs from interactive messages and template quick replies, so tests can "tap" them
  const buttons = body.interactive?.type === 'button'
    ? body.interactive.action.buttons.map((b) => ({ id: b.reply.id, title: b.reply.title }))
    : body.interactive?.type === 'list'
    ? body.interactive.action.sections.flatMap((x) => x.rows).map((r) => ({ id: r.id, title: r.title }))
    : body.interactive?.type === 'flow' ? []
    : (body.template?.components || []).filter((c) => c.type === 'button')
        .map((c) => ({ id: c.parameters?.[0]?.payload, title: 'quick reply ' + c.index }));
  const flow = body.interactive?.type === 'flow' ? body.interactive.action.parameters : undefined;
  const image = body.interactive?.header?.image?.link || body.image?.link;
  state.whatsapp.push({ id, at: new Date().toISOString(), phoneNumberId: m[2], to: body.to, type: body.type, text, buttons, flow, image });
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
  const re = /(?:Court|Facility):\s*(.+)\r?\n\s*Date:\s*(.+)\r?\n\s*(?:Time|Slot):\s*(.+)/g;
  let m;
  while ((m = re.exec(body))) {
    const [start, end] = m[3].split(/\s*[-–]\s*/);
    slots.push({ court: m[1].trim(), date: toIsoDate(m[2]), start_time: to24h(start), end_time: to24h(end) });
  }
  const amount = get(/(?:Amount|Total)[^:\n]*:\s*₹?\s*([\d,]+(?:\.\d+)?)/i);
  const pay = (get(/Payment(?: Status)?:\s*([A-Za-z ]+)/i) || '').toLowerCase();
  return {
    email_type,
    booking_id: get(/Booking (?:ID|Reference):\s*([A-Z0-9-]+)/i),
    customer_name: get(/Customer(?: Name)?:\s*(.+)/i),
    customer_phone: get(/(?:Phone|Mobile):\s*(.+)/i),
    amount: amount ? Number(amount.replace(/,/g, '')) : null,
    payment_status: /partial/.test(pay) ? 'partially_paid' : /unpaid|pay at venue/.test(pay) ? 'unpaid' : /paid/.test(pay) ? 'paid' : 'unknown',
    sport: get(/(?:Sport|Activity):\s*(.+)/i),
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

// Nominatim-shaped geocoder for the travel partner workflows (TRAVEL_GEOCODER_URL=http://mock-apis:8090/geocode/search).
// Coordinates are illustrative. "Civil Lines" exists in several cities, so without a city it is ambiguous.
const PLACES = [
  ['jhunsi', 'prayagraj', 25.4374, 81.9067],
  ['naini', 'prayagraj', 25.3870, 81.8640],
  ['chungi', 'prayagraj', 25.4300, 81.8850],
  ['civil lines', 'prayagraj', 25.4536, 81.8340],
  ['civil lines', 'kanpur', 26.4780, 80.3470],
  ['civil lines', 'delhi', 28.6814, 77.2226],
  ['prayagraj junction', 'prayagraj', 25.4460, 81.8250],
  ['koramangala', 'bangalore', 12.9352, 77.6245],
  ['indiranagar', 'bangalore', 12.9784, 77.6408],
  ['whitefield', 'bangalore', 12.9698, 77.7500],
  ['hsr layout', 'bangalore', 12.9116, 77.6474],
];
const CITY_ALIASES = { allahabad: 'prayagraj', bengaluru: 'bangalore', 'new delhi': 'delhi' };

function geocode(req, res, url) {
  state.geocode.requests++;
  if (state.faults.geocode_fail_next > 0) {
    state.faults.geocode_fail_next--;
    return send(res, 503, { error: 'Service unavailable (injected)' });
  }
  if (!req.headers['user-agent']) return send(res, 403, { error: 'User-Agent required' });
  let q = String(url.searchParams.get('q') || '').toLowerCase();
  for (const [a, c] of Object.entries(CITY_ALIASES)) q = q.replaceAll(a, c);
  const cities = new Set(PLACES.map((p) => p[1]).filter((c) => q.includes(c)));
  let hits = PLACES.filter(([name, city]) => q.includes(name) && (!cities.size || cities.has(city)));
  // prefer the longest name ("prayagraj junction" over a bare city match)
  const longest = Math.max(0, ...hits.map((h) => h[0].length));
  hits = hits.filter((h) => h[0].length === longest);
  send(res, 200, hits.map(([name, city, lat, lng], i) => ({
    place_id: 1000 + i, lat: String(lat), lon: String(lng),
    display_name: `${name.replace(/\b\w/g, (c) => c.toUpperCase())}, ${city[0].toUpperCase() + city.slice(1)}, India`,
    importance: 0.5,
  })));
}

// Razorpay (RAZORPAY_API_URL=http://mock-apis:8090/razorpay/v1): orders, payments, capture. Tests "pay"
// an order with POST /_razorpay/pay { order_id, capture } (capture: false = authorised only).
function razorpay(req, res, path, raw) {
  if (!/^Basic /.test(req.headers.authorization || '')) return send(res, 401, { error: { code: 'BAD_REQUEST_ERROR', description: 'auth' } });
  const rp = state.razorpay;
  if (path === '/razorpay/v1/orders' && req.method === 'POST') {
    const b = parseJson(raw) || {};
    if (!Number.isInteger(b.amount) || b.amount < 100 || b.currency !== 'INR') {
      return send(res, 400, { error: { code: 'BAD_REQUEST_ERROR', description: 'amount' } });
    }
    const id = 'order_' + crypto.randomBytes(7).toString('hex');
    rp.orders[id] = { id, entity: 'order', amount: b.amount, currency: 'INR', receipt: b.receipt, notes: b.notes, status: 'created' };
    return send(res, 200, rp.orders[id]);
  }
  let m = path.match(/^\/razorpay\/v1\/payments\/([\w]+)$/);
  if (m && req.method === 'GET') {
    return rp.payments[m[1]] ? send(res, 200, rp.payments[m[1]])
                             : send(res, 400, { error: { code: 'BAD_REQUEST_ERROR', description: 'The id provided does not exist' } });
  }
  m = path.match(/^\/razorpay\/v1\/payments\/([\w]+)\/capture$/);
  if (m && req.method === 'POST') {
    const pay = rp.payments[m[1]];
    if (!pay || pay.status !== 'authorized') return send(res, 400, { error: { code: 'BAD_REQUEST_ERROR', description: 'not authorized' } });
    pay.status = 'captured';
    return send(res, 200, pay);
  }
  // RazorpayX (ToriPay): contacts, bank fund accounts, payouts. A payout needs the RazorpayX account
  // number and an X-Payout-Idempotency key; the same key returns the same payout.
  const bad = (d) => send(res, 400, { error: { code: 'BAD_REQUEST_ERROR', description: d } });
  if (path === '/razorpay/v1/contacts' && req.method === 'POST') {
    const b = parseJson(raw) || {};
    if (!b.name) return bad('name');
    const id = 'cont_' + crypto.randomBytes(7).toString('hex');
    rp.contacts[id] = { id, entity: 'contact', ...b };
    return send(res, 200, rp.contacts[id]);
  }
  if (path === '/razorpay/v1/fund_accounts' && req.method === 'POST') {
    const b = parseJson(raw) || {};
    const ba = b.bank_account || {};
    if (!rp.contacts[b.contact_id]) return bad('contact_id');
    if (!/^[A-Z]{4}0[A-Z0-9]{6}$/.test(ba.ifsc || '') || !/^\d{9,18}$/.test(ba.account_number || '')) return bad('bank_account');
    const id = 'fa_' + crypto.randomBytes(7).toString('hex');
    rp.fund_accounts[id] = { id, entity: 'fund_account', contact_id: b.contact_id, account_type: 'bank_account', bank_account: ba, active: true };
    return send(res, 200, rp.fund_accounts[id]);
  }
  if (path === '/razorpay/v1/payouts' && req.method === 'POST') {
    const b = parseJson(raw) || {};
    const key = req.headers['x-payout-idempotency'] || '';
    if (!key) return bad('X-Payout-Idempotency');
    if (rp.payout_keys[key]) return send(res, 200, rp.payouts[rp.payout_keys[key]]);
    if (state.faults.payout_fail_next > 0) {
      state.faults.payout_fail_next--;
      return send(res, 500, { error: { code: 'SERVER_ERROR', description: 'injected fault' } });
    }
    if (!b.account_number) return bad('account_number');
    if (!rp.fund_accounts[b.fund_account_id]) return bad('fund_account_id');
    if (!Number.isInteger(b.amount) || b.amount < 100) return bad('amount');
    const id = 'pout_' + crypto.randomBytes(7).toString('hex');
    rp.payouts[id] = { id, entity: 'payout', fund_account_id: b.fund_account_id, amount: b.amount, currency: 'INR', mode: b.mode,
                       purpose: b.purpose, reference_id: b.reference_id, narration: b.narration, status: 'processing', idempotency_key: key };
    rp.payout_keys[key] = id;
    return send(res, 200, rp.payouts[id]);
  }
  send(res, 404, { error: { code: 'BAD_REQUEST_ERROR', description: 'unknown path' } });
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
    geocode: state.geocode,
    tokenRequests: state.tokenRequests,
    payoutRequests: state.payoutRequests,
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
    if (path.startsWith('/razorpay/')) return razorpay(req, res, path, raw);
    if (path === '/_razorpay/pay' && req.method === 'POST') {
      const b = parseJson(raw) || {};
      const order = state.razorpay.orders[b.order_id];
      if (!order) return send(res, 404, { error: 'no such order' });
      const id = 'pay_' + crypto.randomBytes(7).toString('hex');
      state.razorpay.payments[id] = { id, entity: 'payment', order_id: order.id, amount: b.amount ?? order.amount, currency: 'INR',
                                      status: b.capture === false ? 'authorized' : 'captured' };
      order.status = 'paid';
      return send(res, 200, state.razorpay.payments[id]);
    }
    if (path === '/_razorpay/state') return send(res, 200, state.razorpay);
    // Razorpay's IFSC directory (IFSC_API_URL=http://mock-apis:8090/ifsc): a few known codes, 404 otherwise
    if (path.startsWith('/ifsc/') && req.method === 'GET') {
      const BANKS = { HDFC: 'HDFC Bank', ICIC: 'ICICI Bank', SBIN: 'State Bank of India', UTIB: 'Axis Bank' };
      const code = decodeURIComponent(path.slice(6)).toUpperCase();
      const bank = BANKS[code.slice(0, 4)];
      if (!bank || !/^[A-Z]{4}0[A-Z0-9]{6}$/.test(code) || code.endsWith('999999')) return send(res, 404, 'Not Found');
      return send(res, 200, { BANK: bank, BRANCH: 'HSR LAYOUT', CITY: 'BANGALORE', IFSC: code, BANKCODE: code.slice(0, 4) });
    }
    // the web app's payout endpoint, for the WhatsApp tests (TORI_WEB_URL=http://mock-apis:8090)
    if (path === '/api/payouts/execute' && req.method === 'POST') {
      state.payoutRequests.push({ ...(parseJson(raw) || {}), key: req.headers['x-tori-key'] || '' });
      return send(res, 200, { state: 'owed', reason: 'mock' });
    }
    if (path.startsWith('/groq/')) return groq(req, res, path, raw);
    if (path === '/geocode/search' && req.method === 'GET') return geocode(req, res, url);
    send(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: String(err) });
  }
}).listen(PORT, () => console.log(`mock-apis listening on :${PORT}`));
