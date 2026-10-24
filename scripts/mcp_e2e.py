#!/usr/bin/env python3
"""The voice agent and the WhatsApp chat as one conversation, end to end: MCP requests with X-Call-Id (as Vapi sends
them) → web /api/mcp → workflow 06 → the bot's replies, logged on their way out (web /api/graph), back to the agent
and in the (mock) WhatsApp chat. Started by scripts/travel-e2e.sh (E2E_ONLY=mcp runs just this).
Four turns call the real LLM (paced): about 3 minutes.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

WEB = os.environ.get('MCP_E2E_WEB', 'http://localhost:13001')
MOCK = os.environ.get('TRAVEL_E2E_MOCK', 'http://localhost:18090')
CONTAINER = os.environ.get('TRAVEL_E2E_PG', 'toritravel-postgres-1')
KEY = os.environ.get('MCP_E2E_KEY', 'e2e-mcp-key')
N8N_NOTIFY = os.environ.get('MCP_E2E_NOTIFY', 'http://localhost:15678/webhook/wallet/notify')
N8N_INBOUND = os.environ.get('TRAVEL_E2E_WEBHOOK', 'http://localhost:15678/webhook/wa-test')
LLM_GAP = 14
_last_llm = [0.0]
_seq = [0]
failures = []

HOST, PARTNER, JOINER, WALLET, CAB, RAHUL = (f'91940000000{i}' for i in range(1, 7))


def psql(q):
    return subprocess.check_output(['docker', 'exec', CONTAINER, 'psql', '-U', 'tori_app', '-d', 'tori', '-tAc', q],
                                   text=True).strip()


def msgs(to):
    with urllib.request.urlopen(MOCK + '/_state', timeout=30) as r:
        return [m for m in json.loads(r.read())['whatsapp'] if m['to'] == to]


def mcp(body, call_id=None, key=KEY):
    """One MCP request. Returns (HTTP status, parsed JSON or None)."""
    h = {'content-type': 'application/json', 'accept': 'application/json, text/event-stream'}
    if key:
        h['x-tori-mcp-key'] = key
    if call_id:
        h['x-call-id'] = call_id
    req = urllib.request.Request(WEB + '/api/mcp', data=json.dumps(body).encode(), headers=h, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'null')


def tool(name, args=None, call_id=None, llm=False):
    if llm:
        wait = _last_llm[0] + LLM_GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_llm[0] = time.time()
    _seq[0] += 1
    st, r = mcp({'jsonrpc': '2.0', 'id': _seq[0], 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}, call_id)
    out = json.loads(r['result']['content'][0]['text']) if st == 200 and r and 'result' in r else {'http': st, 'body': r}
    print(f'\n▶ {name}({json.dumps(args or {}, ensure_ascii=False)}) as {call_id or "anonymous"}\n  ◀ {json.dumps(out, ensure_ascii=False)[:400]}')
    return out


def replies(wa, since, want=1, timeout=60):
    end = time.time() + timeout
    while time.time() < end and len(msgs(wa)[since:]) < want:
        time.sleep(1)
    time.sleep(3)
    got = msgs(wa)[since:]
    for g in got:
        print(f'  ◀ WhatsApp to {wa[-2:]}: ' + (g['text'] or '').replace('\n', '\n             ')[:300])
    return got


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def on_call(wa, name, vapi_id, state='active'):
    """A WhatsApp call in progress, as voice-bridge logs it (db 015)."""
    psql(f"INSERT INTO voice_calls (channel, meta_call_id, vapi_call_id, caller_wa_id, caller_name, state) "
         f"VALUES ('whatsapp', 'wacid.{vapi_id}', '{vapi_id}', '{wa}', '{name}', '{state}')")


def chat(wa, name, text=None, button=None, llm=False):
    """The same person typing (or tapping) in their WhatsApp chat. Returns the bot's replies."""
    if llm:
        wait = _last_llm[0] + LLM_GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_llm[0] = time.time()
    _seq[0] += 1
    m = ({'type': 'interactive', 'interactive': {'type': 'button_reply', 'button_reply': {'id': button, 'title': 'x'}}} if button
         else {'type': 'text', 'text': {'body': text}})
    n = len(msgs(wa))
    print(f'\n▶ chat {name} ({wa[-2:]}): {text or button}')
    urllib.request.urlopen(urllib.request.Request(N8N_INBOUND, method='POST', headers={'content-type': 'application/json'}, data=json.dumps(
        {'messaging_product': 'whatsapp', 'metadata': {'phone_number_id': '100000000000002'}, 'contacts': [{'profile': {'name': name}, 'wa_id': wa}],
         'messages': [{'from': wa, 'id': f'wamid.MCPCHAT{_seq[0]:04d}', 'timestamp': str(int(time.time())), **m}]}).encode()), timeout=30)
    return replies(wa, n, timeout=60)


def context(wa):
    rq = urllib.request.Request(WEB + '/api/agent/context', data=json.dumps({'wa_id': wa}).encode(),
                                headers={'content-type': 'application/json', 'x-tori-mcp-key': KEY}, method='POST')
    with urllib.request.urlopen(rq, timeout=30) as r:
        return json.loads(r.read())['text']


def complete_profile(wa, name, interest):
    psql(f"SELECT public.tori_user('{wa}', '{name}')")
    psql(f"UPDATE tori_users SET name = '{name}', name_source = 'user', birth_year = 2000, gender = 'female', interests = '{{{interest}}}', "
         f"skipped = '{{social,photo,about}}', profile_status = 'complete' WHERE phone = '+{wa}'")


def say(call_id, text=None, button=None, llm=False):
    """One turn of the call: the caller's words (or the button they chose) → Tori's replies. When the LLM is busy
    (Groq's free tier), the bot says it's having trouble: try again once, as the agent would."""
    r = tool('message_tori', {'button_id': button} if button else {'text': text}, call_id=call_id, llm=llm)
    if llm and 'having a little trouble' in said(r):
        time.sleep(20)
        r = tool('message_tori', {'text': text}, call_id=call_id, llm=llm)
    return r


def btn(r, prefix):
    return next((b['id'] for x in r.get('replies') or [] for b in x.get('buttons') or [] if b['id'].startswith(prefix)), None)


def said(r):
    return '\n---\n'.join(x['text'] for x in r.get('replies') or [])


# ── 1. Protocol, key and the WhatsApp pass-through ─────────────────────────────────────────────────
st, _ = mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}, key=None)
check(st == 401, 'no key → 401')
st, _ = mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}, key='wrong')
check(st == 401, 'wrong key → 401')
st, r = mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
             'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'vapi', 'version': '1'}}})
check(st == 200 and r['result']['protocolVersion'] == '2025-06-18' and 'tools' in r['result']['capabilities']
      and r['result']['serverInfo']['name'] == 'tori', 'initialize: protocol version, tools capability, server info')
st, r = mcp({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
check(st == 202 and r is None, 'notification → 202, no body')
st, r = mcp({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
names = [t['name'] for t in r['result']['tools']]
check(names == ['message_tori', 'check_tori_replies', 'search_open_games', 'get_my_status'], f'tools/list: {", ".join(names)}')
st, r = mcp({'jsonrpc': '2.0', 'id': 3, 'method': 'nope'})
check(r['error']['code'] == -32601, 'unknown method → -32601')
try:
    urllib.request.urlopen(WEB + '/api/mcp', timeout=10)
    check(False, 'GET → 405')
except urllib.error.HTTPError as e:
    check(e.code == 405, 'GET → 405 (no SSE stream)')
for hdr, want, label in (({'cf-ray': 'x', 'authorization': 'Bearer t'}, 404, 'through the public tunnel → 404'),
                         ({}, 401, 'without a token → 401')):
    try:
        urllib.request.urlopen(urllib.request.Request(WEB + '/api/graph/123/messages', data=b'{}', headers=hdr, method='POST'), timeout=10)
        check(False, 'WhatsApp pass-through: ' + label)
    except urllib.error.HTTPError as e:
        check(e.code == want, 'WhatsApp pass-through: ' + label)

# ── 2. A game on the board; anyone can search; the caller's own status ───────────────────────────
psql(f"SELECT public.tori_user('{HOST}', 'Hema Rao')")
psql(f"""SELECT public.save_partner_request('{HOST}', 'Hema Rao', jsonb_build_object(
  'activity', 'badminton', 'city', 'bangalore', 'area', 'HSR Layout', 'area_key', 'hsrlayout',
  'play_date', ((now() AT TIME ZONE 'Asia/Kolkata')::date + 1)::text, 'time_label', 'around 7 PM', 'players_needed', 2,
  'window_start', (((now() AT TIME ZONE 'Asia/Kolkata')::date + 1 + time '18:30') AT TIME ZONE 'Asia/Kolkata')::text,
  'window_end', (((now() AT TIME ZONE 'Asia/Kolkata')::date + 1 + time '19:30') AT TIME ZONE 'Asia/Kolkata')::text), true)""")
code = psql(f"SELECT join_code FROM partner_requests WHERE wa_id = '{HOST}'")
r = tool('search_open_games', {'activity': 'badminton', 'city': 'bangalore', 'area': 'HSR'})
g = next((x for x in r.get('games') or [] if x.get('join_code') == code), {})
check(g.get('host') == 'Hema' and g.get('area') == 'HSR Layout' and 'wa_id' not in json.dumps(r),
      'search: Hema\'s badminton game with its join code, first name only')
check(tool('get_my_status').get('status') == 'not_identified', 'anonymous (web page) → not identified')
check(say(None, 'add credits').get('status') == 'not_identified', 'anonymous message_tori → not identified')
on_call(HOST, 'Hema Rao', 'vapi-e2e-host')
r = tool('get_my_status', call_id='vapi-e2e-host')
check((r.get('partner_requests') or [{}])[0].get('code') == code and r.get('wallet_balance') == '₹0', 'Hema: her game, ₹0 wallet')

# ── 3. One conversation: the bot's reply comes back to the agent and lands in the chat with the echo ──
on_call(WALLET, 'Wasim', 'vapi-e2e-wallet')
n = len(msgs(WALLET))
r = say('vapi-e2e-wallet', 'add credits')
w = msgs(WALLET)[n:]
check(r.get('status') == 'ok' and 'Tori Wallet' in said(r) and 'wallet/login?t=' in said(r), 'agent gets the bot\'s wallet reply to say')
check(w and w[0]['text'].startswith('📞 _On your call: "add credits"_') and 'Tori Wallet' in w[0]['text'],
      'the chat shows it too, starting with what he said on the call')
check(not said(r).startswith('📞'), '… the agent gets it without the echo')
check(psql(f"SELECT count(*) FROM tori_messages m JOIN tori_users u ON u.id = m.user_id WHERE u.phone = '+{WALLET}' "
           f"AND m.direction = 'out' AND m.payload IS NOT NULL") == '1', 'the bot\'s message is logged with its payload')
r = say('vapi-e2e-wallet', 'invite')
check(len(r.get('replies') or []) == 2 and 'TORI-' in said(r), 'invite: both bot messages come back (code + message to forward)')

# ── 4. No account yet: the agent sends the caller to WhatsApp, the request carries on once it is set up ──
on_call(JOINER, 'Jai Kumar', 'vapi-e2e-joiner')
check(context(JOINER).startswith('No Tori account yet'), 'call starts: the agent is told Jai has no Tori account yet')
n = len(msgs(JOINER))
r = say('vapi-e2e-joiner', f'JOIN {code}')
w = msgs(JOINER)[n:]
check(r.get('status') == 'needs_account' and 'WhatsApp' in r.get('note', ''), 'JOIN on the call → "set up your account in WhatsApp"')
check(w and 'Before I send your request to join' in w[0]['text'] and w[0]['text'].startswith('📞'),
      'the setup questions arrive in his chat (with what he said on the call)')
check(say('vapi-e2e-joiner', '26', llm=True).get('status') == 'needs_account', 'answering the setup on the call → back to the chat')
check('wallet/login?t=' in said(say('vapi-e2e-joiner', 'add credits')), '… but the wallet link still works on the call during setup')
r = chat(JOINER, 'Jai Kumar', button='pf_name_wa')
r = chat(JOINER, 'Jai Kumar', button='pf_gender_male') if 'gender' in (r[-1]['text'] if r else '') else chat(JOINER, 'Jai Kumar', '26', llm=True)
if r and 'gender' in r[-1]['text']:
    r = chat(JOINER, 'Jai Kumar', button='pf_gender_male')
r = chat(JOINER, 'Jai Kumar', 'badminton and cricket', llm=True)
for skip in ('pf_skip_social', 'pf_skip_photo', 'pf_skip_about'):
    if r and any(b['id'] == skip for b in r[-1].get('buttons') or []):
        r = chat(JOINER, 'Jai Kumar', button=skip)
check(any("asked Hema" in m['text'] for m in r), 'account set up in the chat → the join from the call goes to Hema by itself')
check(context(JOINER).startswith('Name: Jai Kumar (confirmed)') and 'Profile: complete' in context(JOINER),
      'next call: the agent knows his confirmed name and complete profile')

# ── 5. Missing details: the bot asks, on the call, then it's posted ──────────────────────────────
complete_profile(PARTNER, 'Priya', 'tennis')
on_call(PARTNER, 'Priya', 'vapi-e2e-partner')
r = say('vapi-e2e-partner', 'I want to play tennis tomorrow in Indiranagar, Bangalore', llm=True)
check('What time' in said(r), 'no time given → the bot asks "What time works for you?" and the agent hears it')
r = say('vapi-e2e-partner', '6 pm', llm=True)
check('Looking for a tennis partner tomorrow around 6 PM in Indiranagar' in said(r), '"6 pm" → posted: "Looking for a tennis partner…"')
check(psql(f"SELECT status FROM partner_requests WHERE wa_id = '{PARTNER}'") == 'open', 'the request is open, as from the chat')
texts = [m['text'] for m in msgs(PARTNER)]
check(len(texts) == 2 and texts[0].startswith('📞 _On your call: "I want to play tennis') and texts[1].startswith('📞 _On your call: "6 pm"_'),
      'her chat has both, each with what she said on the call')

# ── 6. A match offer on the call: "interested" said out loud is the button ───────────────────────
complete_profile(RAHUL, 'Rahul', 'tennis')
on_call(RAHUL, 'Rahul', 'vapi-e2e-rahul')
r = say('vapi-e2e-rahul', 'tennis tomorrow 6:30 pm in Indiranagar, Bangalore', llm=True)
if not btn(r, 'pm_yes_'):
    time.sleep(6)
    r = tool('check_tori_replies', call_id='vapi-e2e-rahul')
check(btn(r, 'pm_yes_') and 'Priya' in said(r), 'Rahul posts on the call → Priya\'s card comes back with Interested / Not interested')
r = say('vapi-e2e-rahul', 'interested')
check('Priya' in said(r) and ('asked' in said(r) or 'saved it' in said(r)), '"interested" (said, not tapped) → Tori asks Priya')

# ── 6b. Something arriving later (a match, an update) is picked up with check_tori_replies ─────────
r = tool('check_tori_replies', call_id='vapi-e2e-partner')
check('Rahul' in said(r) and btn(r, 'pm_yes_'), 'Priya, still on her call: Rahul\'s card (found meanwhile) comes back with its buttons')
check(tool('check_tori_replies', call_id='vapi-e2e-partner').get('status') == 'nothing_new', 'then nothing new')
rq = urllib.request.Request(N8N_NOTIFY, data=json.dumps({'wa_id': PARTNER, 'text': 'Your court is booked for 6 PM'}).encode(),
                            headers={'content-type': 'application/json', 'x-tori-key': 'e2e-wallet-key'}, method='POST')
urllib.request.urlopen(rq, timeout=30)
time.sleep(4)
r = tool('check_tori_replies', call_id='vapi-e2e-partner')
check(r.get('status') == 'ok' and 'court is booked' in said(r), 'a later bot message comes back with check_tori_replies')

# ── 7. Started on the call, asked about in the chat: one conversation ─────────────────────────────
check(context(CAB).startswith('No Tori account yet'), 'call starts: the agent is told Chetan has no account')
on_call(CAB, 'Chetan', 'vapi-e2e-cab')
n = len(msgs(CAB))
r = say('vapi-e2e-cab', 'I need a cab buddy from Indiranagar to Koramangala, Bangalore tomorrow 9 am', llm=True)
w = msgs(CAB)[n:]
check(r.get('status') == 'needs_account' and w and '*Chetan*' in w[0]['text'],
      'cab buddy on the call → "set up in WhatsApp"; his chat asks him to confirm his name')
_last_llm[0] = time.time()                      # the confirmed request is replayed through the LLM
r = chat(CAB, 'Chetan', button='nm_yes')
time.sleep(6)
check(any('Koramangala' in m['text'] for m in msgs(CAB)[n:]), 'Yes in the chat → the trip from the call is taken (in the chat)')
st = tool('get_my_status', call_id='vapi-e2e-cab')
check('Koramangala' in json.dumps(st.get('cab_buddy_request')), 'back on the call, get_my_status shows the cab request')
w = chat(CAB, 'Chetan', 'Am I looking for any cab?', llm=True)
check(w and '🚕 Cab buddy: Indiranagar' in w[-1]['text'] and 'Koramangala' in w[-1]['text'],
      'typed "Am I looking for any cab?" → the bot shows the trip from the call, not a new request')

# ── 8. "Which area?" answered with a place the LLM doesn't know, then two people the same game → a match ──
complete_profile(RAHUL_A := '919400000011', 'Arjun', 'tennis')
complete_profile(RAHUL_B := '919400000012', 'Bhavna', 'tennis')
w = chat(RAHUL_A, 'Arjun', 'Tennis tomorrow 9:00 PM in Bangalore', llm=True)
check(w and 'Which area in Bangalore?' in w[-1]['text'], 'no area → "Which area in Bangalore?"')
w = chat(RAHUL_A, 'Arjun', 'HSL Bangalore', llm=True)
check(w and 'Looking for a tennis partner tomorrow around 9 PM in HSL' in w[-1]['text'] and 'Here\'s what I can do' not in w[-1]['text'],
      '"HSL Bangalore" (an area the LLM doesn\'t know) → posted in HSL, not the menu')
check(psql(f"SELECT status || '|' || area_key FROM partner_requests WHERE wa_id = '{RAHUL_A}'") == 'open|hsl', 'Arjun\'s request is open, area hsl')
w = chat(RAHUL_B, 'Bhavna', 'Tennis tomorrow 9 PM at HSL Bangalore', llm=True)
time.sleep(5)
check(psql(f"SELECT count(*) FROM partner_matches WHERE '{RAHUL_B}' IN (wa_a, wa_b) AND '{RAHUL_A}' IN (wa_a, wa_b)") == '1'
      and any(b['id'].startswith('pm_yes_') for m in msgs(RAHUL_B) for b in m.get('buttons') or []),
      'Bhavna posts the same game → matched with Arjun, she gets his card')

# ── 9. An ended call can no longer act ────────────────────────────────────────────────────────────
psql("UPDATE voice_calls SET state = 'ended', ended_at = now() - interval '10 minutes' WHERE vapi_call_id = 'vapi-e2e-wallet'")
check(say('vapi-e2e-wallet', 'balance').get('status') == 'not_identified', 'a call that ended 10 min ago can no longer act')

print(f'\n{"FAILED: " + str(len(failures)) if failures else "all MCP checks passed"}')
for f in failures:
    print('  ✘', f)
sys.exit(1 if failures else 0)
