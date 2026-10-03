#!/usr/bin/env python3
"""Generate the travel-partner sub-workflows (07–12) for the Tori WhatsApp bot.

    python3 plan/build_travel_workflows.py

Writes n8n/workflows/07-travel-assistant.json … 12-travel-sweep.json. Workflow 06 (the bot) hands
travel messages to 07; build_partner_workflow.py adds that hook. Every rule (matching, consent,
dedupe, rate limits, expiry, what may be shown to whom) is a Postgres function in
db/migrations/005_travel_functions.repeatable.sql; these workflows only orchestrate.

    06 WhatsApp bot ──► 07 assistant ──► 08 geocode (cache → Nominatim / Google)
                              │      └──► 10 consent / block / report
                              ▼
                        09 find matches ◄── 10, 12 (re-match)
                              │
    07, 09, 10, 12 ─────► 11 notify (render + send + log)      12 sweep: every 10 minutes
"""
import json
import uuid
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'n8n' / 'workflows'

# Same credentials as the bot (workflow 06): its database, its WhatsApp number.
CRED_PG = {'postgres': {'id': 'xzG9f2LEMKhGXmqg', 'name': 'Postgres account'}}
CRED_WA = {'httpHeaderAuth': {'id': 'toriWhatsAppHdr1', 'name': 'WhatsApp Cloud API'}}
GRAPH_URL = ("={{ ($env.BOT_WHATSAPP_GRAPH_URL || 'https://graph.facebook.com/v19.0') + '/' + "
             "$env.BOT_WHATSAPP_PHONE_NUMBER_ID + '/messages' }}")

WF = {
    'assistant': ('toriTravelAssist', '07-travel-assistant', 'Tori 07 · Travel · assistant',
                  'Handles a travel message from the WhatsApp bot (06): dedupe, collect missing details, '
                  'geocode, save the TravelIntent, start matching. Also routes yes / no / block / report.'),
    'geocode': ('toriTravelGeocod', '08-travel-geocode', 'Tori 08 · Travel · geocode',
                'Place text → lat/lng. Postgres cache first, then the provider in TRAVEL_GEOCODER '
                '(nominatim or google). Returns ok / not_found / ambiguous / error.'),
    'match': ('toriTravelMatchs', '09-travel-match', 'Tori 09 · Travel · find matches',
              'Runs travel_find_matches() for each TravelIntent and notifies the requester about the best '
              'candidate. Returns only { matchFound, matchId }.'),
    'consent': ('toriTravelConsnt', '10-travel-consent', 'Tori 10 · Travel · consent',
                'Yes / no / block / report on a travel match: travel_respond() decides, then notify and re-match.'),
    'notify': ('toriTravelNotify', '11-travel-notify', 'Tori 11 · Travel · notify',
               'Every travel WhatsApp message: reads what may be shared (travel_notification), renders the text, '
               'sends it (text, buttons, or the approved template outside the 24-hour window) and logs the result.'),
    'sweep': ('toriTravelSweep1', '12-travel-sweep', 'Tori 12 · Travel · sweep',
              'Every 10 minutes: expire unanswered matches, past trips and abandoned drafts; tell whoever was '
              'waiting; look for new candidates.'),
}

# Matching configuration: env var → key read by public.travel_cfg() (which holds the defaults).
CFG_ENV = {
    'max_source_km': 'TRAVEL_MAX_SOURCE_DISTANCE_KM',
    'max_destination_km': 'TRAVEL_MAX_DESTINATION_DISTANCE_KM',
    'max_time_diff_min': 'TRAVEL_MAX_TIME_DIFFERENCE_MINUTES',
    'max_candidates': 'TRAVEL_MAX_MATCH_CANDIDATES',
    'w_source': 'TRAVEL_SCORE_WEIGHT_SOURCE',
    'w_destination': 'TRAVEL_SCORE_WEIGHT_DESTINATION',
    'w_time': 'TRAVEL_SCORE_WEIGHT_TIME',
    'consent_timeout_min': 'TRAVEL_CONSENT_TIMEOUT_MINUTES',
    'intent_grace_min': 'TRAVEL_INTENT_GRACE_MINUTES',
    'draft_ttl_min': 'TRAVEL_DRAFT_TTL_MINUTES',
    'max_days_ahead': 'TRAVEL_MAX_DAYS_AHEAD',
    'max_changes_per_hour': 'TRAVEL_MAX_REQUEST_CHANGES_PER_HOUR',
    'max_changes_per_day': 'TRAVEL_MAX_REQUEST_CHANGES_PER_DAY',
    'decline_cooldown_days': 'TRAVEL_DECLINE_COOLDOWN_DAYS',
    'geocode_cache_days': 'TRAVEL_GEOCODE_CACHE_DAYS',
}
CFG = 'JSON.stringify({ ' + ', '.join(f'{k}: $env.{v}' for k, v in CFG_ENV.items()) + ' })'

HTTP = ('n8n-nodes-base.httpRequest', 4.2)
PG = ('n8n-nodes-base.postgres', 2.6)
CODE = ('n8n-nodes-base.code', 2)
IF = ('n8n-nodes-base.if', 2.2)
SWITCH = ('n8n-nodes-base.switch', 3.2)
SET = ('n8n-nodes-base.set', 3.4)
EXEC = ('n8n-nodes-base.executeWorkflow', 1.2)


class Workflow:
    def __init__(self, key):
        self.id, self.file, self.name, self.description = WF[key]
        self.nodes, self.conns = {}, {}

    def nid(self, name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f'tori/{self.id}/{name}'))

    def add(self, name, type_, version, params, col, row, **extra):
        assert name not in self.nodes, name
        node = {'parameters': params, 'id': self.nid(name), 'name': name, 'type': type_,
                'typeVersion': version, 'position': [260 * col, 200 * row]}
        node.update(extra)
        self.nodes[name] = node
        return name

    def link(self, src, dst, out=0):
        outs = self.conns.setdefault(src, {}).setdefault('main', [])
        while len(outs) <= out:
            outs.append([])
        outs[out].append({'node': dst, 'type': 'main', 'index': 0})

    def chain(self, *names):
        for a, b in zip(names, names[1:]):
            self.link(a, b)

    def write(self):
        for src, by_type in self.conns.items():
            assert src in self.nodes, src
            for outs in by_type.values():
                for out in outs:
                    for c in out:
                        assert c['node'] in self.nodes, f'{src} -> {c["node"]}'
        wf = {
            'id': self.id, 'name': self.name, 'description': self.description,
            'nodes': list(self.nodes.values()), 'connections': self.conns,
            'settings': {'executionOrder': 'v1', 'saveManualExecutions': True,
                         'callerPolicy': 'workflowsFromSameOwner', 'timezone': 'Asia/Kolkata'},
            'pinData': {}, 'tags': [], 'active': False,
        }
        path = OUT / f'{self.file}.json'
        path.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + '\n')
        print(f'wrote {path.relative_to(OUT.parent.parent)} ({len(self.nodes)} nodes)')


def code(js, each=False):
    p = {'jsCode': js.strip() + '\n'}
    return {'mode': 'runOnceForEachItem', **p} if each else {'mode': 'runOnceForAllItems', **p}


def sql(query, params=None):
    p = {'operation': 'executeQuery', 'query': query.strip(), 'options': {}}
    if params:
        p['options']['queryReplacement'] = '={{ ' + params + ' }}'
    return p


def bool_if(wf, name, expr):
    return {
        'conditions': {
            'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose', 'version': 2},
            'conditions': [{'id': wf.nid(name + '/cond'), 'leftValue': '={{ ' + expr + ' }}', 'rightValue': '',
                            'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
            'combinator': 'and',
        },
        'looseTypeValidation': True,
        'options': {},
    }


def route_switch(routes, field='$json.route'):
    return {'mode': 'expression', 'numberOutputs': len(routes),
            'output': '={{ ' + json.dumps(routes) + '.indexOf(' + field + ') }}'}


def call(key, wait):
    return {'workflowId': {'__rl': True, 'mode': 'id', 'value': WF[key][0]},
            'options': {'waitForSubWorkflow': wait}}


def tail(wf, pg, suffix, col, row, rematch=True):
    """Common ending after a command function: send its notifications, then search for its rematch list."""
    msgs = wf.add(f'Messages ({suffix})', *CODE, code(f"""
// notifications decided by the database; workflow 11 renders and sends them
return $('{pg}').all().flatMap((i) => i.json.r.notifications || []).map((n) => ({{ json: n }}));
"""), col, row, alwaysOutputData=True)
    notify = wf.add(f'Notify ({suffix})', *EXEC, call('notify', True), col + 1, row, alwaysOutputData=True)
    wf.chain(pg, msgs, notify)
    if rematch:
        todo = wf.add(f'Requests to match ({suffix})', *CODE, code(f"""
const ids = [...new Set($('{pg}').all().flatMap((i) => i.json.r.rematch || []))];
return ids.map((intent_id) => ({{ json: {{ intent_id }} }}));
"""), col + 2, row)
        match = wf.add(f'Find matches ({suffix})', *EXEC, call('match', False), col + 3, row)
        wf.chain(notify, todo, match)


def trigger(wf, col=0, row=0):
    return wf.add('When called', 'n8n-nodes-base.executeWorkflowTrigger', 1.1, {'inputSource': 'passthrough'}, col, row)


# ══════════════════════════════════════════════════════════════════════════════════════════════
# 07 · assistant
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('assistant')
trigger(w)
w.add('Register message', *PG, sql(
    "SELECT public.travel_begin_message($1, $2, $3) AS u;",
    "[ $json.wa_id, $json.profile_name || '', $json.message_id || '' ]"), 1, 0, credentials=CRED_PG)
w.add('New message?', *IF, bool_if(w, 'New message?', '!$json.u.duplicate'), 2, 0)
w.chain('When called', 'Register message', 'New message?')

w.add('Route', *CODE, code(r"""
// What the person wants. The LLM (workflow 06) already classified the message; buttons carry the match ID.
const msg = $('When called').first().json;
const user_id = $json.u.user_id;
const t = msg.travel || {};
const reply = (kind, text = '') => ({ json: { route: 'reply', user_id, kind, text } });
const respond = (action, match_id = '', reason = '') => ({ json: { route: 'respond', user_id, action, match_id, reason } });

if (msg.intent === 'travel_button') {
  const m = String(msg.button_id || '').match(/^tm_(yes|no|block)_([0-9a-f-]{36})$/);
  if (!m) return reply('match_unavailable');
  return respond({ yes: 'accept', no: 'decline', block: 'block' }[m[1]], m[2]);
}
if (msg.intent === 'travel_start') {
  // "🚕 Cab buddy" from the services menu: start (or show) their trip request
  return { json: { route: 'request', user_id, from_menu: true, travel: { source: null, destination: null, date: null, time: null } } };
}
if (msg.intent === 'travel_form') {
  // WhatsApp Flow reply: date is YYYY-MM-DD (newer Flow versions) or a timestamp in ms (older ones)
  const raw = t.date;
  const date = raw && /^\d{10,}$/.test(String(raw))
    ? DateTime.fromMillis(Number(raw), { zone: 'Asia/Kolkata' }).toISODate() : (raw || null);
  return { json: { route: 'request', user_id, from_form: true,
    travel: { source: t.source || null, destination: t.destination || null, date, time: t.time || null } } };
}
switch (msg.intent) {
  case 'travel_consent':
    if (t.consent === 'accept' || t.consent === 'decline') return respond(t.consent);
    return reply('reply', 'Would you like to connect with them? Just reply yes or no 🙂');
  case 'travel_block':
    return respond('block');
  case 'travel_report':
    return respond('report', '', String(t.reason || '').slice(0, 500));
  case 'travel_cancel':
    return { json: { route: 'cancel', user_id } };
  default:
    return { json: { route: 'request', user_id,
      travel: { source: t.source ?? null, destination: t.destination ?? null, date: t.date ?? null, time: t.time ?? null } } };
}
"""), 3, 0)
w.link('New message?', 'Route', 0)
w.add('Travel route', *SWITCH, route_switch(['request', 'cancel', 'respond', 'reply']), 4, 0)
w.link('Route', 'Travel route')

# ── request: merge with the unfinished request, validate, ask or geocode ───────────────────────
w.add('Load travel request', *PG, sql(
    'SELECT public.travel_load_request($1::uuid, $2::jsonb) AS r;', f'[ $json.user_id, {CFG} ]'),
    5, -2, credentials=CRED_PG)
w.link('Travel route', 'Load travel request', 0)

w.add('Validate travel details', *CODE, code(r"""
// Deterministic: merge the newly extracted fields into the person's unfinished request, check the
// day and time, and work out which details are still missing. The LLM never decides this.
const ZONE = 'Asia/Kolkata';
const MAX_DAYS = Number($env.TRAVEL_MAX_DAYS_AHEAD) || 30;
const { user_id, travel: ai, from_form, from_menu } = $('Route').first().json;
const loaded = $json.r || {};
const cur = loaded.request || {};
const now = DateTime.now().setZone(ZONE);
const today = now.startOf('day');
const at = (day, hhmm) => { const [h, m] = hhmm.split(':').map(Number); return day.set({ hour: h, minute: m, second: 0, millisecond: 0 }); };
const clean = (s) => (typeof s === 'string' && s.trim()) ? s.trim().replace(/\s+/g, ' ').slice(0, 120) : null;

const changing = ai.source || ai.destination || ai.date || ai.time;
if (loaded.rate_limited && changing) return { json: { route: 'reply', user_id, kind: 'rate_limited' } };

// newest answer wins
const f = {
  source_text: clean(ai.source) ?? cur.source ?? null,
  destination_text: clean(ai.destination) ?? cur.destination ?? null,
  travel_date: ai.date ?? cur.date ?? null,
  departure_time: ai.time ?? cur.time ?? null,
};
const problems = [];
if (f.travel_date && !(/^\d{4}-\d{2}-\d{2}$/.test(f.travel_date) && DateTime.fromISO(f.travel_date, { zone: ZONE }).isValid)) {
  problems.push("I couldn't understand the date. Which day are you travelling?");
  f.travel_date = null;
}
if (f.departure_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(f.departure_time)) f.departure_time = null;
// a time with no day ("at 6 PM") means today, if that is still ahead
if (!f.travel_date && f.departure_time && !problems.length && at(today, f.departure_time) > now.plus({ minutes: 5 })) {
  f.travel_date = today.toISODate();
}
if (f.travel_date) {
  const d = DateTime.fromISO(f.travel_date, { zone: ZONE });
  if (d < today) { problems.push('That date has already passed. Which day are you travelling?'); f.travel_date = null; }
  else if (d > today.plus({ days: MAX_DAYS })) { problems.push(`I can only look up to ${MAX_DAYS} days ahead. Which day are you travelling?`); f.travel_date = null; }
  else if (f.departure_time && at(d, f.departure_time) <= now) { problems.push('That time has already passed. What time are you leaving?'); f.departure_time = null; }
}
if (f.source_text && f.destination_text && f.source_text.toLowerCase() === f.destination_text.toLowerCase()) {
  problems.push('Your start and destination look the same. Where are you going?');
  f.destination_text = null;
}

// ask only for what is missing (at most two questions)
const ask = [...problems];
const has = (s) => ask.some((q) => q.includes(s));
if (!f.source_text && !f.destination_text) ask.push('Where are you travelling from, and where are you going?');
else if (!f.source_text) ask.push('Where will you be starting from?');
else if (!f.destination_text && !has('destination')) ask.push('Where are you going?');
if (!f.travel_date && !f.departure_time) { if (!has('Which day')) ask.push('When are you leaving? (e.g. tomorrow 6 PM)'); }
else if (!f.travel_date) { if (!has('Which day')) ask.push('Which day are you travelling?'); }
else if (!f.departure_time && !has('time')) ask.push('What time are you planning to leave?');

// Details missing and the WhatsApp trip form is set up: send the form (pre-filled) instead of questions
if (ask.length && !problems.length && !from_form && $env.TRAVEL_TRIP_FLOW_ID) {
  return { json: { route: 'ask', user_id, kind: 'trip_form', text: '', fields: f } };
}
if (ask.length && from_menu) {
  return { json: { route: 'ask', user_id, kind: 'reply', fields: f, text: '🚕 *Cab buddy*: tell me your trip and I\'ll look for someone '
    + 'going the same way. Your number and exact places stay private unless you both agree to connect.\n\n'
    + 'Where are you travelling from and to, and when?\ne.g. "Jhunsi to Civil Lines, today 6 PM"' } };
}
if (ask.length) {
  const known = f.source_text || f.destination_text || f.travel_date || f.departure_time;
  return { json: { route: 'ask', user_id, kind: 'reply', fields: f,
    text: (problems.length ? '' : known ? 'Got it. ' : 'Sure! ') + ask.slice(0, 2).join('\n') } };
}
return { json: { route: 'geocode', user_id, fields: f } };
"""), 6, -2)
w.add('Details route', *SWITCH, route_switch(['geocode', 'ask', 'reply']), 7, -2)
w.chain('Load travel request', 'Validate travel details', 'Details route')

# one draft save for both "missing details" and "unclear place"; it echoes the question to send
w.add('Save draft', *PG, sql(
    'SELECT public.travel_save_draft($1::uuid, $2::jsonb) AS id, $1 AS user_id, $3 AS text, $4 AS kind;',
    "[ $json.user_id, JSON.stringify($json.fields), $json.text || '', $json.kind || 'reply' ]"), 12, -1, credentials=CRED_PG)
w.add('Send reply', *EXEC, call('notify', True), 13, 0)
w.link('Details route', 'Save draft', 1)
w.link('Details route', 'Send reply', 2)
w.link('Travel route', 'Send reply', 3)
w.link('Save draft', 'Send reply')

w.add('Source place', *SET, {
    'assignments': {'assignments': [
        {'id': w.nid('src/q'), 'name': 'query', 'value': '={{ $json.fields.source_text }}', 'type': 'string'},
        {'id': w.nid('src/u'), 'name': 'user_id', 'value': '={{ $json.user_id }}', 'type': 'string'}]},
    'options': {}}, 8, -3)
w.add('Geocode source', *EXEC, call('geocode', True), 9, -3)
w.add('Destination place', *SET, {
    'assignments': {'assignments': [
        {'id': w.nid('dst/q'), 'name': 'query',
         'value': "={{ $('Validate travel details').first().json.fields.destination_text }}", 'type': 'string'},
        {'id': w.nid('dst/u'), 'name': 'user_id',
         'value': "={{ $('Validate travel details').first().json.user_id }}", 'type': 'string'}]},
    'options': {}}, 10, -3)
w.add('Geocode destination', *EXEC, call('geocode', True), 11, -3)
w.link('Details route', 'Source place', 0)
w.chain('Source place', 'Geocode source', 'Destination place', 'Geocode destination')

w.add('Check places', *CODE, code(r"""
// Both places must resolve to one clear point. Coordinates stay in the backend.
const v = $('Validate travel details').first().json;
const src = $('Geocode source').first().json;
const dst = $json;
const user_id = v.user_id;
const f = { ...v.fields };
if (src.status === 'error' || dst.status === 'error' || !src.status || !dst.status) {
  return { json: { route: 'reply', user_id, kind: 'reply',
    text: "Sorry, I couldn't check those places right now. Please send your trip again in a minute 🙏" } };
}
const ask = [];
for (const [g, key, label] of [[src, 'source_text', 'starting point'], [dst, 'destination_text', 'destination']]) {
  if (g.status === 'not_found') {
    ask.push(`I couldn't find "${f[key]}" on the map. What's your ${label}? An area or landmark with the city works best (e.g. "Jhunsi, Prayagraj").`);
    f[key] = null;
  } else if (g.status === 'ambiguous') {
    ask.push(`There's more than one "${f[key]}". Which city or district is your ${label} in?`);
  }
}
if (!ask.length) {
  const rad = (d) => d * Math.PI / 180;
  const a = Math.sin(rad(dst.lat - src.lat) / 2) ** 2 + Math.cos(rad(src.lat)) * Math.cos(rad(dst.lat)) * Math.sin(rad(dst.lng - src.lng) / 2) ** 2;
  if (2 * 6371 * Math.asin(Math.sqrt(a)) < 0.3) {
    ask.push('Your start and destination look like the same place. Where are you going?');
    f.destination_text = null;
  }
}
if (ask.length) return { json: { route: 'ask', user_id, kind: 'reply', fields: f, text: ask.join('\n') } };
return { json: { route: 'save', user_id, fields: {
  ...f, source_lat: src.lat, source_lng: src.lng, destination_lat: dst.lat, destination_lng: dst.lng } } };
"""), 12, -3)
w.add('Places route', *SWITCH, route_switch(['save', 'ask', 'reply']), 13, -3)
w.chain('Geocode destination', 'Check places', 'Places route')
w.link('Places route', 'Save draft', 1)
w.link('Places route', 'Send reply', 2)

w.add('Save travel intent', *PG, sql(
    'SELECT public.travel_activate_intent($1::uuid, $2::jsonb, $3::jsonb) AS r;',
    f'[ $json.user_id, JSON.stringify($json.fields), {CFG} ]'), 14, -4, credentials=CRED_PG)
w.link('Places route', 'Save travel intent', 0)
tail(w, 'Save travel intent', 'intent', 15, -4)

# ── cancel ──────────────────────────────────────────────────────────────────────────────────────
w.add('Cancel travel request', *PG, sql(
    'SELECT public.travel_cancel_intent($1::uuid) AS r;', '[ $json.user_id ]'), 5, 2, credentials=CRED_PG)
w.link('Travel route', 'Cancel travel request', 1)
tail(w, 'Cancel travel request', 'cancel', 6, 2)

# ── yes / no / block / report ──────────────────────────────────────────────────────────────────
w.add('Consent, block or report', *EXEC, call('consent', True), 5, 4)
w.link('Travel route', 'Consent, block or report', 2)
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 08 · geocode (one place per call)
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('geocode')
trigger(w)
w.add('Normalise place', *CODE, code(r"""
const provider = String($env.TRAVEL_GEOCODER || 'nominatim').toLowerCase() === 'google' ? 'google' : 'nominatim';
const query = String($json.query || '').trim().replace(/\s+/g, ' ').slice(0, 200);
const norm = query.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
return { json: { user_id: $json.user_id || '', query, provider, key: provider + ':' + norm } };
""", each=True), 1, 0)
w.add('Look up cache', *PG, sql(
    "SELECT public.travel_geocode_lookup($1, nullif($2, '')::uuid, $3::jsonb) AS hit;",
    f'[ $json.key, $json.user_id, {CFG} ]'), 2, 0, credentials=CRED_PG)
w.add('In cache?', *IF, bool_if(w, 'In cache?', '!!$json.hit'), 3, 0)
w.chain('When called', 'Normalise place', 'Look up cache', 'In cache?')
w.add('From cache', *CODE, code("""
return { json: { status: 'ok', lat: $json.hit.lat, lng: $json.hit.lng, cached: true } };
""", each=True), 4, -1)
w.link('In cache?', 'From cache', 0)

w.add('Provider', *SWITCH, {'mode': 'expression', 'numberOutputs': 2,
                            'output': "={{ $('Normalise place').first().json.provider === 'google' ? 0 : 1 }}"}, 4, 1)
w.link('In cache?', 'Provider', 1)
GEO_OPTS = {'timeout': 10000, 'response': {'response': {'fullResponse': True, 'neverError': True}}}
w.add('Google geocoding', *HTTP, {
    'url': "={{ $env.TRAVEL_GEOCODER_URL || 'https://maps.googleapis.com/maps/api/geocode/json' }}",
    'sendQuery': True, 'queryParameters': {'parameters': [
        {'name': 'address', 'value': "={{ $('Normalise place').first().json.query }}"},
        {'name': 'region', 'value': "={{ $env.TRAVEL_GEOCODER_COUNTRY || 'in' }}"},
        {'name': 'key', 'value': '={{ $env.TRAVEL_GEOCODER_KEY }}'}]},
    'options': GEO_OPTS}, 5, 0, onError='continueRegularOutput')
w.add('Nominatim search', *HTTP, {
    'url': "={{ $env.TRAVEL_GEOCODER_URL || 'https://nominatim.openstreetmap.org/search' }}",
    'sendQuery': True, 'queryParameters': {'parameters': [
        {'name': 'q', 'value': "={{ $('Normalise place').first().json.query }}"},
        {'name': 'format', 'value': 'jsonv2'},
        {'name': 'limit', 'value': '5'},
        {'name': 'countrycodes', 'value': "={{ $env.TRAVEL_GEOCODER_COUNTRY || 'in' }}"},
        {'name': 'accept-language', 'value': 'en'}]},
    # Nominatim's usage policy requires an identifying User-Agent
    'sendHeaders': True, 'headerParameters': {'parameters': [
        {'name': 'User-Agent', 'value': "={{ $env.TRAVEL_GEOCODER_USER_AGENT || 'ToriWhatsAppBot/1.0' }}"}]},
    'options': GEO_OPTS}, 5, 2, onError='continueRegularOutput')
w.link('Provider', 'Google geocoding', 0)
w.link('Provider', 'Nominatim search', 1)

w.add('Read results', *CODE, code(r"""
// ok = one clear place; ambiguous = the top results are far apart (e.g. "Civil Lines" exists in many cities)
const p = $('Normalise place').first().json;
const AMBIGUITY_KM = Number($env.TRAVEL_GEOCODE_AMBIGUITY_KM) || 25;
let places = null;
if ($json.statusCode === 200) {
  const b = $json.body;
  if (p.provider === 'google') {
    if (b && (b.status === 'OK' || b.status === 'ZERO_RESULTS')) {
      places = (b.results || []).map((x) => ({ lat: x.geometry.location.lat, lng: x.geometry.location.lng, label: x.formatted_address }));
    }
  } else if (Array.isArray(b)) {
    places = b.map((x) => ({ lat: Number(x.lat), lng: Number(x.lon), label: x.display_name }));
  }
}
const rad = (d) => d * Math.PI / 180;
const km = (a, b) => 2 * 6371 * Math.asin(Math.sqrt(Math.sin(rad(b.lat - a.lat) / 2) ** 2
  + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lng - a.lng) / 2) ** 2));
let status = 'ok';
if (!places) status = 'error';
else if (!places.length) status = 'not_found';
else if (places.slice(1).some((x) => km(places[0], x) > AMBIGUITY_KM)) status = 'ambiguous';
const best = status === 'ok' ? places[0] : {};
return { json: { status, lat: best.lat ?? null, lng: best.lng ?? null, label: best.label ?? null,
                 provider: p.provider, key: p.key, user_id: p.user_id, http_status: $json.statusCode ?? null } };
""", each=True), 6, 1)
w.link('Google geocoding', 'Read results')
w.link('Nominatim search', 'Read results')
w.add('Found?', *IF, bool_if(w, 'Found?', "$json.status === 'ok'"), 7, 1)
w.link('Read results', 'Found?')
w.add('Save to cache', *PG, sql(
    "SELECT public.travel_geocode_store($1, $2, $3::float8, $4::float8, $5, nullif($6, '')::uuid);",
    '[ $json.key, $json.provider, $json.lat, $json.lng, $json.label || "", $json.user_id ]'),
    8, 0, credentials=CRED_PG)
w.add('Place found', *CODE, code("""
const r = $('Read results').first().json;
return [{ json: { status: 'ok', lat: r.lat, lng: r.lng, cached: false } }];
"""), 9, 0)
w.add('Log geocode failure', *PG, sql(
    "SELECT public.travel_log('travel.geocode.failure', nullif($1, '')::uuid, NULL, NULL, $2::jsonb);",
    '[ $json.user_id, JSON.stringify({ provider: $json.provider, status: $json.status, http_status: $json.http_status }) ]'),
    8, 2, credentials=CRED_PG)
w.add('Place not usable', *CODE, code("""
return [{ json: { status: $('Read results').first().json.status } }];
"""), 9, 2)
w.link('Found?', 'Save to cache', 0)
w.link('Found?', 'Log geocode failure', 1)
w.link('Save to cache', 'Place found')
w.link('Log geocode failure', 'Place not usable')
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 09 · find matches (items: { intent_id })
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('match')
trigger(w)
w.add('Find matches', *PG, sql(
    'SELECT public.travel_find_matches($1::uuid, $2::jsonb) AS r;', f'[ $json.intent_id, {CFG} ]'),
    1, 0, credentials=CRED_PG)
w.link('When called', 'Find matches')
tail(w, 'Find matches', 'match', 2, 0, rematch=False)
w.add('Result', *CODE, code("""
// The only thing the matcher hands back: no places, distances or other users
return $('Find matches').all().map((i) => ({ json: { matchFound: !!i.json.r.matchFound, matchId: i.json.r.matchId || null } }));
"""), 4, 0)
w.link('Notify (match)', 'Result')
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 10 · consent / decline / block / report (items: { user_id, action, match_id, reason })
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('consent')
trigger(w)
w.add('Record answer', *PG, sql(
    "SELECT public.travel_respond($1::uuid, nullif($2, '')::uuid, $3, nullif($4, ''), $5::jsonb) AS r;",
    f"[ $json.user_id, $json.match_id || '', $json.action, $json.reason || '', {CFG} ]"),
    1, 0, credentials=CRED_PG)
w.link('When called', 'Record answer')
tail(w, 'Record answer', 'consent', 2, 0)
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 11 · notify (items: { user_id, kind, match_id?, text? })
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('notify')
trigger(w)
w.add('Has recipient?', *IF, bool_if(w, 'Has recipient?', '!!$json.user_id && !!$json.kind'), 1, 0)
w.add('Recipient', *PG, sql(
    "SELECT public.travel_notification($1::uuid, nullif($2, '')::uuid) AS n, $1 AS user_id, $2 AS match_id, $3 AS kind, $4 AS text;",
    "[ $json.user_id, $json.match_id || '', $json.kind, $json.text || '' ]"), 2, 0, credentials=CRED_PG)
w.chain('When called', 'Has recipient?')
w.link('Has recipient?', 'Recipient', 0)

w.add('Render message', *CODE, code(r"""
// All travel message wording lives here. `n` comes from travel_notification(), which only returns
// the person's own trip, the other trip's rounded departure time and, once BOTH said yes, the other
// person's first name and number.
const ZONE = 'Asia/Kolkata';
const { n, user_id, kind, match_id, text } = $json;
const skip = (reason) => ({ json: { send: false, user_id, kind, match_id, reason } });
if (!n || !n.wa_id) return skip('unknown_user');

const now = DateTime.now().setZone(ZONE);
const day = (iso) => {
  if (!iso) return '';
  const d = DateTime.fromISO(String(iso).slice(0, 10), { zone: ZONE });
  // always show the date too, so a wrong day is obvious ("tomorrow" said at 2 AM is ambiguous)
  const date = d.toFormat('ccc d LLL');
  return d.hasSame(now, 'day') ? `today (${date})` : d.hasSame(now.plus({ days: 1 }), 'day') ? `tomorrow (${date})` : 'on ' + date;
};
const clock = (hhmm) => {
  if (!hhmm) return '';
  const t = DateTime.fromFormat(String(hhmm).slice(0, 5), 'HH:mm');
  return t.toFormat(t.minute ? 'h:mm a' : 'h a');
};
const trip = n.my_source ? `${n.my_source} → ${n.my_destination}, ${day(n.my_date)} around ${clock(n.my_time)}` : 'your trip';
const yesNo = [{ id: 'tm_yes_' + match_id, title: 'Yes, connect' }, { id: 'tm_no_' + match_id, title: 'No thanks' }];
const looking = "I'm still looking for someone else on your route 🔍";

const M = {
  reply: () => text,
  trip_form: () => [(n.my_source || n.my_destination)
    ? 'Got it 👍 Tap below to fill in the rest of your trip.'
    : 'Sure! Tap below and tell me your trip: where from, where to, the day and roughly what time.', 'FORM'],
  request_created: () => `Got it ✅ ${trip}.\n\nI'll look for someone travelling a similar route and message you here if I find a match. Nobody sees your number or exact locations unless you both agree to connect.\n\nTo stop, just say "cancel my travel request".`,
  request_updated: () => `Updated ✅ ${trip}.\n\nI'm looking again with the new details 🔍`,
  request_unchanged: () => `You already have this request: ${trip}. I'll message you as soon as I find someone 🔍`,
  rate_limited: () => "You've changed your travel request a lot in a short time. Please wait a while before changing it again 🙏",
  in_past: () => 'That time has already passed. When are you leaving? (e.g. tomorrow 6 PM)',
  too_far: () => `That's too far ahead for me (up to ${Number($env.TRAVEL_MAX_DAYS_AHEAD) || 30} days). Which day are you travelling?`,
  cancelled_ack: () => "Done ✅ I've cancelled your travel partner request. Message me any time to start a new one.",
  nothing_to_cancel: () => "You don't have an open travel partner request right now.",
  offer: () => [`Hi 👋\n\nWe found someone travelling a similar route around the same time.\n\nThey're starting from a nearby area and heading toward a similar destination, leaving around ${clock(n.their_time)} ${day(n.their_date)}.\n\nWould you like to connect?`, yesNo],
  request_b: () => [`Hi 👋\n\nWe found someone travelling a similar route around the same time as your trip (${trip}).\n\nThey're leaving around ${clock(n.their_time)} and would like to connect with you. Would you like to connect?`, yesNo],
  a_waiting: () => "Great 👍 I've asked them. I'll message you as soon as they reply.\n\nYour number stays private unless you both say yes.",
  connected: () => n.their_wa_id && [`✅ You're connected!\n\n${n.their_name || 'Your travel partner'} also wants to travel together ${day(n.their_date)}, leaving around ${clock(n.their_time)}.\n\nSay hi 👉 https://wa.me/${n.their_wa_id}\n\nStay safe: meet in a busy public place, tell someone you trust about your trip, and never share OTPs or payment details. To report them, reply "report" and tell me what happened.`,
    [{ id: 'tm_block_' + match_id, title: 'Block' }]],
  declined_ack: () => "No problem 👍 I won't connect you. Your request stays open, and I'll message you if someone else matches.",
  counterpart_declined: () => `They can't make it this time. Your request stays open — ${looking}`,
  counterpart_timeout: () => `I didn't hear back from them, so I've closed that match. ${looking}`,
  match_withdrawn: () => `That match is no longer available because their plans changed. ${looking}`,
  match_unavailable: () => "This match isn't available any more. I'll message you if I find someone else 🔍",
  already_connected: () => "You're already connected ✅ Scroll up for their WhatsApp link.",
  nothing_pending: () => "There's no match waiting for your answer right now. I'll message you as soon as I find someone 🔍",
  no_match_to_block: () => "I couldn't find a recent travel match to block or report.",
  blocked_ack: () => "Done 🚫 You won't be matched with this person again.",
  reported_ack: () => "Thanks for telling us 🙏 We've recorded your report, and you won't be matched with this person again. If you ever feel unsafe, call 112.",
};
if (!M[kind]) return skip('unknown_kind');
let body = M[kind]();
if (!body) return skip(kind === 'connected' ? 'not_connected' : 'empty');
const [msg, buttons] = Array.isArray(body) ? body : [body, null];

let payload;
if (!n.inside_window) {
  // Outside WhatsApp's 24-hour window only an approved template may be sent
  const tpl = $env.TRAVEL_MATCH_TEMPLATE;
  if (!(tpl && (kind === 'offer' || kind === 'request_b'))) return skip('outside_24h_window');
  payload = { messaging_product: 'whatsapp', to: n.wa_id, type: 'template', template: {
    name: tpl, language: { code: $env.TRAVEL_TEMPLATE_LANG || 'en' },
    components: [
      { type: 'body', parameters: [{ type: 'text', text: clock(n.their_time) }, { type: 'text', text: day(n.their_date) }] },
      { type: 'button', sub_type: 'quick_reply', index: '0', parameters: [{ type: 'payload', payload: 'tm_yes_' + match_id }] },
      { type: 'button', sub_type: 'quick_reply', index: '1', parameters: [{ type: 'payload', payload: 'tm_no_' + match_id }] },
    ] } };
} else if (buttons === 'FORM') {
  // WhatsApp Flow form (n8n/whatsapp-flows/travel_trip.json), pre-filled with what we already know
  const today = now.startOf('day');
  const parameters = {
    flow_message_version: '3', flow_token: 'travel_trip', flow_id: $env.TRAVEL_TRIP_FLOW_ID,
    flow_cta: 'Fill trip details', flow_action: 'navigate',
    flow_action_payload: { screen: 'TRIP', data: {
      source: n.my_source || '', destination: n.my_destination || '',
      min_date: today.toISODate(), max_date: today.plus({ days: Number($env.TRAVEL_MAX_DAYS_AHEAD) || 30 }).toISODate() } },
  };
  if ($env.TRAVEL_TRIP_FLOW_MODE === 'draft') parameters.mode = 'draft';
  payload = { messaging_product: 'whatsapp', to: n.wa_id, type: 'interactive', interactive: {
    type: 'flow', body: { text: msg }, action: { name: 'flow', parameters } } };
} else if (buttons) {
  payload = { messaging_product: 'whatsapp', to: n.wa_id, type: 'interactive', interactive: {
    type: 'button', body: { text: msg.slice(0, 1024) },
    action: { buttons: buttons.map((b) => ({ type: 'reply', reply: b })) } } };
} else {
  payload = { messaging_product: 'whatsapp', to: n.wa_id, type: 'text', text: { preview_url: false, body: msg } };
}
return { json: { send: true, user_id, kind, match_id, payload } };
""", each=True), 3, 0)
w.add('Can send?', *IF, bool_if(w, 'Can send?', '$json.send'), 4, 0)
w.chain('Recipient', 'Render message', 'Can send?')
w.add('Send WhatsApp', *HTTP, {
    'method': 'POST', 'url': GRAPH_URL,
    'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
    'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.payload) }}',
    'options': {'timeout': 20000, 'response': {'response': {'fullResponse': True, 'neverError': True}}},
}, 5, -1, credentials=CRED_WA, onError='continueRegularOutput')
w.add('Log delivery', *PG, sql(
    "SELECT public.travel_log($1, nullif($2, '')::uuid, NULL, nullif($3, '')::uuid, $4::jsonb) AS logged;",
    "[ $json.statusCode === 200 ? 'travel.notification.sent' : 'travel.notification.failed', "
    "$('Render message').item.json.user_id, $('Render message').item.json.match_id || '', "
    "JSON.stringify({ kind: $('Render message').item.json.kind, http_status: $json.statusCode ?? null, "
    "error_code: $json.body?.error?.code ?? $json.error?.code ?? null }) ]"), 6, -1, credentials=CRED_PG)
w.add('Log skipped', *PG, sql(
    "SELECT public.travel_log('travel.notification.skipped', nullif($1, '')::uuid, NULL, nullif($2, '')::uuid, $3::jsonb) AS logged;",
    "[ $json.user_id, $json.match_id || '', JSON.stringify({ kind: $json.kind, reason: $json.reason }) ]"),
    5, 1, credentials=CRED_PG)
w.link('Can send?', 'Send WhatsApp', 0)
w.link('Can send?', 'Log skipped', 1)
w.link('Send WhatsApp', 'Log delivery')
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 12 · sweep
# ══════════════════════════════════════════════════════════════════════════════════════════════
w = Workflow('sweep')
w.add('Every 10 minutes', 'n8n-nodes-base.scheduleTrigger', 1.2,
      {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 10}]}}, 0, 0)
w.add('Expire trips and matches', *PG, sql('SELECT public.travel_sweep($1::jsonb) AS r;', f'[ {CFG} ]'),
      1, 0, credentials=CRED_PG)
w.link('Every 10 minutes', 'Expire trips and matches')
tail(w, 'Expire trips and matches', 'sweep', 2, 0)
w.write()

# ══════════════════════════════════════════════════════════════════════════════════════════════
# WhatsApp Flow "trip form" (static, no endpoint). Created in Meta by scripts/create-travel-flow.sh;
# workflow 11 sends it (kind trip_form) when TRAVEL_TRIP_FLOW_ID is set; the reply comes back as an
# nfm_reply with flow token "travel_trip" and is handled by 06 → 07 like a typed request.
# ══════════════════════════════════════════════════════════════════════════════════════════════
def slot(h, m):
    return {'id': f'{h:02d}:{m:02d}', 'title': f"{(h % 12) or 12}:{m:02d} {'AM' if h < 12 else 'PM'}"}


FLOW = {
    'version': '7.0',
    'screens': [{
        'id': 'TRIP',
        'title': 'Find a cab buddy',
        'terminal': True,
        'success': True,
        'data': {
            'source': {'type': 'string', '__example__': 'Jhunsi, Prayagraj'},
            'destination': {'type': 'string', '__example__': 'Civil Lines, Prayagraj'},
            'min_date': {'type': 'string', '__example__': '2026-10-04'},
            'max_date': {'type': 'string', '__example__': '2026-11-03'},
        },
        'layout': {'type': 'SingleColumnLayout', 'children': [
            {'type': 'TextSubheading', 'text': 'Where and when are you going?'},
            {'type': 'TextBody', 'text': "We'll look for someone travelling a similar route. Your number and exact "
                                         "places stay private unless you both agree to connect."},
            {'type': 'TextInput', 'name': 'source', 'label': 'From (area, city)', 'input-type': 'text',
             'required': True, 'init-value': '${data.source}', 'helper-text': 'e.g. Jhunsi, Prayagraj'},
            {'type': 'TextInput', 'name': 'destination', 'label': 'To (area, city)', 'input-type': 'text',
             'required': True, 'init-value': '${data.destination}', 'helper-text': 'e.g. Civil Lines, Prayagraj'},
            {'type': 'DatePicker', 'name': 'date', 'label': 'Travel date', 'required': True,
             'min-date': '${data.min_date}', 'max-date': '${data.max_date}'},
            {'type': 'Dropdown', 'name': 'time', 'label': 'Leaving around', 'required': True,
             'data-source': [slot(h, m) for h in range(24) for m in (0, 15, 30, 45)]},
            {'type': 'Footer', 'label': 'Find a cab buddy', 'on-click-action': {
                'name': 'complete',
                'payload': {'source': '${form.source}', 'destination': '${form.destination}',
                            'date': '${form.date}', 'time': '${form.time}'}}},
        ]},
    }],
}
flow_path = OUT.parent / 'whatsapp-flows' / 'travel_trip.json'
flow_path.parent.mkdir(exist_ok=True)
flow_path.write_text(json.dumps(FLOW, indent=2, ensure_ascii=False) + '\n')
print(f'wrote {flow_path.relative_to(OUT.parent.parent)}')
