#!/usr/bin/env python3
"""Travel partner matching end to end: WhatsApp-shaped webhooks → workflow 06 (test copy) → 07–12.

Started by scripts/travel-e2e.sh, which brings up an isolated stack with real Groq and mock
WhatsApp / geocoder. Checks the conversation, the database state and the privacy rules.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

N8N = os.environ.get('TRAVEL_E2E_WEBHOOK', 'http://localhost:15678/webhook/wa-test')
MOCK = os.environ.get('TRAVEL_E2E_MOCK', 'http://localhost:18090')
CONTAINER = os.environ.get('TRAVEL_E2E_PG', 'toritravel-postgres-1')
LLM_GAP = 14          # seconds between LLM-backed messages (Groq free tier: 8k tokens/minute)
_last_llm = [0.0]
_seq = [0]
failures = []


def http(url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'content-type': 'application/json'}, method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b'null')


def psql(q):
    out = subprocess.check_output(['docker', 'exec', CONTAINER, 'psql', '-U', 'tori_app', '-d', 'tori',
                                   '-tAc', q], text=True)
    return out.strip()


def msgs(to):
    return [m for m in http(MOCK + '/_state')['whatsapp'] if m['to'] == to]


def send(wa, name, text=None, button=None, msg_id=None, llm=True, form=None, list_id=None):
    if llm:
        wait = _last_llm[0] + LLM_GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_llm[0] = time.time()
    _seq[0] += 1
    msg_id = msg_id or f'wamid.TEST{_seq[0]:04d}'
    m = {'from': wa, 'id': msg_id, 'timestamp': str(int(time.time()))}
    if form is not None:   # WhatsApp Flow submission
        m.update(type='interactive', interactive={'type': 'nfm_reply', 'nfm_reply': {
            'name': 'flow', 'body': 'Sent', 'response_json': json.dumps({**form, 'flow_token': 'travel_trip'})}})
    elif list_id:          # a row picked from a list menu
        m.update(type='interactive', interactive={'type': 'list_reply', 'list_reply': {'id': list_id, 'title': 'x'}})
    elif button:
        m.update(type='interactive', interactive={'type': 'button_reply', 'button_reply': {'id': button, 'title': 'x'}})
    else:
        m.update(type='text', text={'body': text})
    before = {w: len(msgs(w)) for w in (wa,)}
    http(N8N, {'messaging_product': 'whatsapp', 'metadata': {'phone_number_id': '100000000000002'},
               'contacts': [{'profile': {'name': name}, 'wa_id': wa}], 'messages': [m]})
    print(f'\n▶ {name} ({wa[-2:]}): {text or button or list_id or ("form " + json.dumps(form))}')
    return msg_id, before[wa]


def replies(wa, since, want=1, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        got = msgs(wa)[since:]
        if len(got) >= want:
            time.sleep(1.5)  # let any follow-up message land too
            got = msgs(wa)[since:]
            for g in got:
                print(f'  ◀ to {wa[-2:]}: ' + g['text'].replace('\n', '\n             ') +
                      (f"   {[b['id'][:12] + '…' for b in g['buttons']]}" if g.get('buttons') else ''))
            return got
        time.sleep(1)
    got = msgs(wa)[since:]
    print(f'  ◀ to {wa[-2:]}: only {len(got)} of {want} message(s) within {timeout}s: ' + ' | '.join(g['text'][:80] for g in got))
    return got


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def button(msg, prefix):
    return next((b['id'] for b in msg.get('buttons') or [] if b['id'].startswith(prefix)), None)


A, B, C, D, E, F = '919811100001', '919811100002', '919811100003', '919811100004', '919811100005', '919811100006'
http(MOCK + '/_reset', {})
# names confirmed up front: "Please confirm your name" before matching is tested in scripts/name_e2e.py
for wa, nm in ((A, 'Asha Verma'), (B, 'Bharat Singh'), (C, 'Chetan'), (D, 'Dev'), (E, 'Esha'), (F, 'Farhan')):
    psql(f"SELECT public.tori_user('{wa}', '{nm}')")
    psql(f"UPDATE tori_users SET name_source = 'user' WHERE phone = '+{wa}'")

# ── spec §22: A with missing details ───────────────────────────────────────────────────────────
_, n = send(A, 'Asha Verma', 'Bro I need someone to go to Naini tomorrow evening.')
r = replies(A, n)
form = (r[-1].get('flow') or {}) if r else {}
data = form.get('flow_action_payload', {}).get('data', {})
check(form.get('flow_id') == 'mock-flow-1' and form.get('mode') == 'draft' and 'Naini' in data.get('destination', '')
      and not data.get('source'), 'details missing → trip form, pre-filled with the destination')
tomorrow = time.strftime('%Y-%m-%d', time.localtime(time.time() + 86400))
_, n = send(A, 'Asha Verma', form={'source': 'Jhunsi, Prayagraj', 'destination': data.get('destination') or 'Naini, Prayagraj',
                                   'date': tomorrow, 'time': '18:00'}, llm=False)
r = replies(A, n)
check(r and 'Jhunsi' in r[-1]['text'] and 'Naini' in r[-1]['text'] and '6 PM' in r[-1]['text'] and 'tomorrow' in r[-1]['text'],
      'A confirmed: Jhunsi → Naini, tomorrow around 6 PM')
check(psql("SELECT status FROM travel_intents i JOIN travel_users u ON u.id = i.user_id WHERE u.wa_id = '%s'" % A) == 'ACTIVE',
      'A stored ACTIVE with coordinates')
time.sleep(3)
check(len(msgs(A)) == 2, 'A gets no match message (nobody else yet)')

# ── B later, complete in one message; matching finds A (reverse direction) ─────────────────────
_, n = send(B, 'Bharat Singh', 'I need someone from Chungi to Naini tomorrow around 6:30')
r = replies(B, n, want=2)
check(len(r) == 2 and 'Chungi' in r[0]['text'], 'B: ack first')
offer = r[-1] if r else {}
check(bool(button(offer, 'tm_yes_')), 'B: match offer with Yes/No buttons')
check('Jhunsi' not in offer.get('text', '') and 'km' not in offer.get('text', '') and A not in offer.get('text', '')
      and 'Asha' not in offer.get('text', ''), 'offer reveals no place, distance, name or number')
check('6 PM' in offer.get('text', ''), 'offer shows the coarse departure time')
row = psql("SELECT source_distance_km || '|' || destination_distance_km || '|' || time_difference_minutes || '|' || match_score FROM travel_matches")
print('  (backend only) src km | dst km | minutes | score =', row)

# B taps Yes → A is asked
n_a = len(msgs(A))
_, n = send(B, 'Bharat Singh', button=button(offer, 'tm_yes_'), llm=False)
r = replies(B, n)
check(r and 'asked them' in r[-1]['text'], 'B: waiting message')
ra = replies(A, n_a)
req = ra[-1] if ra else {}
check(bool(button(req, 'tm_yes_')) and 'Jhunsi' in req.get('text', '') and 'Chungi' not in req.get('text', ''),
      'A asked with buttons; sees her own trip, not B\'s place')
check(psql('SELECT status FROM travel_matches') == 'USER_A_ACCEPTED', 'match USER_A_ACCEPTED')
check(all(B not in m['text'] and A not in m['text'] for m in msgs(A) + msgs(B)), 'no phone numbers shared before both said yes')

# duplicate delivery of B's tap: ignored
mid, n = send(B, 'Bharat Singh', button=button(offer, 'tm_yes_'), msg_id='wamid.TEST-DUP', llm=False)
replies(B, n, timeout=8)
send(B, 'Bharat Singh', button=button(offer, 'tm_yes_'), msg_id='wamid.TEST-DUP', llm=False)
time.sleep(8)
check(len(msgs(B)) == n + 1, 'redelivered message (same wamid) handled once')

# A taps Yes → connected
n_b = len(msgs(B))
_, n = send(A, 'Asha Verma', button=button(req, 'tm_yes_'), llm=False)
ra = replies(A, n)
rb = replies(B, n_b)
check(ra and f'wa.me/{B}' in ra[-1]['text'] and 'Bharat' in ra[-1]['text'], 'A gets B\'s link after both said yes')
check(rb and f'wa.me/{A}' in rb[-1]['text'] and 'Asha' in rb[-1]['text'], 'B gets A\'s link after both said yes')
check(psql('SELECT status FROM travel_matches') == 'CONNECTED', 'match CONNECTED')
_, n = send(A, 'Asha Verma', button=button(req, 'tm_yes_'), llm=False)
r = replies(A, n)
check(r and 'already connected' in r[-1]['text'], 'double tap after connect')

# ── C: ambiguous place, follow-up, update, cancel ───────────────────────────────────────────────
_, n = send(C, 'Chetan', 'Need a travel buddy from Civil Lines to the bus adda tomorrow at 6 pm')
r = replies(C, n)
check(r and 'more than one' in r[-1]['text'] and "couldn't find" in r[-1]['text'],
      'ambiguous "Civil Lines" + unknown place: asks which city and for another place')
_, n = send(C, 'Chetan', 'Civil Lines in Prayagraj, and I am going to Naini')
r = replies(C, n)
check(r and 'Civil Lines' in r[-1]['text'] and 'Got it' in r[-1]['text'], 'C created after naming the city')
_, n = send(C, 'Chetan', 'Change my travel time to 7 PM')
r = replies(C, n)
check(r and 'Updated' in r[-1]['text'] and '7 PM' in r[-1]['text'], 'C updated to 7 PM')
check(psql("SELECT version FROM travel_intents i JOIN travel_users u ON u.id = i.user_id WHERE u.wa_id = '%s' AND status = 'ACTIVE'" % C) == '2',
      'version bumped')
_, n = send(C, 'Chetan', 'Cancel my travel partner request')
r = replies(C, n)
check(r and 'cancelled' in r[-1]['text'], 'C cancelled')

# ── decline: E waits, F matches, F says no ──────────────────────────────────────────────────────
_, n = send(E, 'Esha', 'Looking for someone going from Koramangala to Whitefield on Tuesday at 9 am')
replies(E, n)
_, n = send(F, 'Farhan', 'anyone travelling Koramangala to Whitefield tuesday 9:15 am? want to share a cab')
r = replies(F, n, want=2)
offer = r[-1] if r else {}
_, n = send(F, 'Farhan', 'no thanks', llm=True)
r = replies(F, n)
check(r and "won't connect" in r[-1]['text'], 'typed "no thanks" declines (LLM consent → backend state)')
check(psql("SELECT status || '/' || close_reason FROM travel_matches ORDER BY created_at DESC LIMIT 1") == 'DECLINED/declined_by_a',
      'match DECLINED')
time.sleep(3)
check(not any('Would you like to connect' in m['text'] for m in msgs(E)), 'E was never told about the declined match')

# ── block / report ──────────────────────────────────────────────────────────────────────────────
_, n = send(A, 'Asha Verma', 'block this person')
r = replies(A, n)
check(r and "won't be matched" in r[-1]['text'], 'A blocks B')
_, n = send(B, 'Bharat Singh', 'I want to report this user, she never showed up')
r = replies(B, n)
check(r and 'report' in r[-1]['text'], 'B reports A')
check(psql('SELECT count(*) FROM travel_blocks') == '2' and psql('SELECT count(*) FROM travel_reports') == '1', 'blocks + report rows')

# ── services menu: grouped list with Cab buddy; tapping it opens the trip form ─────────────────
_, n = send(D, 'Dev', 'hi', llm=False)
r = replies(D, n)
menu = next((x for x in r if x['type'] == 'interactive'), {})
check(any(b['id'] == 'travel_buddy' for b in menu.get('buttons') or []) and 'Hi Dev' in menu.get('text', ''),
      'menu: greets by name, lists 🚕 Cab buddy')
_, n = send(D, 'Dev', list_id='travel_buddy', llm=False)
r = replies(D, n)
check(r and (r[-1].get('flow') or {}).get('flow_id') == 'mock-flow-1', 'tapping Cab buddy opens the trip form')

# ── sports flow still works (regression) ────────────────────────────────────────────────────────
_, n = send(D, 'Dev', 'Football tomorrow 9 PM in Indiranagar, Bangalore')
r = replies(D, n)
check(r and 'quick questions' in r[-1]['text'], 'sports partner: a new user is asked for a profile first')

# ── logs carry no phone numbers or coordinates ──────────────────────────────────────────────────
ev = psql("SELECT string_agg(details::text, ' ') FROM travel_events")
check(not any(x in (ev or '') for x in (A, B, '25.4', '81.8', 'Jhunsi')), 'travel_events has no numbers, coordinates or places')
print('\n' + psql("SELECT string_agg(event || '=' || n, ', ') FROM (SELECT event, count(*) n FROM travel_events GROUP BY 1 ORDER BY 1) x"))

print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
sys.exit(1 if failures else 0)
