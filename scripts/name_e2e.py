#!/usr/bin/env python3
""""Please confirm your name" before matching, end to end: WhatsApp-shaped webhooks → workflow 06 (test copy)
→ Postgres → mock WhatsApp. Started by scripts/travel-e2e.sh (E2E_ONLY=name runs just this). Scenarios 4 and 5
call the real LLM (paced), the rest don't: about 2 minutes.
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

ROCKY, HARSH, MEERA, BUSY, COOL = (f'91930000000{i}' for i in range(1, 6))
PARTNER = ('2', '🎯Partner for an Activity')
CONNECT = ('1', '🤝Connect-MyPerfect Match')
CAB = ('travel_buddy', '🚕 Cab buddy')


def http(url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'content-type': 'application/json'}, method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b'null')


def psql(q):
    return subprocess.check_output(['docker', 'exec', CONTAINER, 'psql', '-U', 'tori_app', '-d', 'tori', '-tAc', q],
                                   text=True).strip()


def msgs(to):
    return [m for m in http(MOCK + '/_state')['whatsapp'] if m['to'] == to]


def send(wa, name, text=None, button=None, pick=None, llm=False):
    """A text, a button tap or a menu pick ((id, title)) from `wa`. Returns the reply count before."""
    if llm:
        wait = _last_llm[0] + LLM_GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_llm[0] = time.time()
    _seq[0] += 1
    if button:
        m = {'type': 'interactive', 'interactive': {'type': 'button_reply', 'button_reply': {'id': button, 'title': 'x'}}}
    elif pick:
        m = {'type': 'interactive', 'interactive': {'type': 'list_reply', 'list_reply': {'id': pick[0], 'title': pick[1]}}}
    else:
        m = {'type': 'text', 'text': {'body': text}}
    before = len(msgs(wa))
    http(N8N, {'messaging_product': 'whatsapp', 'metadata': {'phone_number_id': '100000000000002'},
               'contacts': [{'profile': {'name': name}, 'wa_id': wa}],
               'messages': [{'from': wa, 'id': f'wamid.NAME{_seq[0]:04d}', 'timestamp': str(int(time.time())), **m}]})
    print(f'\n▶ {name} ({wa[-2:]}): {text or button or ("[menu: " + pick[1] + "]")}')
    return before


def replies(wa, since, want=1, timeout=60, settle=3):
    end = time.time() + timeout
    while time.time() < end and len(msgs(wa)[since:]) < want:
        time.sleep(1)
    time.sleep(settle)
    got = msgs(wa)[since:]
    for g in got:
        extra = f"   {[b['id'] for b in g['buttons']]}" if g.get('buttons') else ''
        print(f'  ◀ to {wa[-2:]}: ' + (g['text'] or '').replace('\n', '\n             ') + extra)
    return got


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def has_buttons(m, *ids):
    return {b['id'] for b in (m or {}).get('buttons') or []} >= set(ids)


def user(wa):
    return psql(f"SELECT name || '|' || name_source FROM tori_users WHERE phone = '+{wa}'")


# ── 1. A WhatsApp name that isn't a real name: "No, change it" → typed → the service goes on ──────
n = send(ROCKY, '🔥Rocky🔥 Singh', pick=PARTNER)
r = replies(ROCKY, n)
check(r and 'Before I look for a partner, could you please confirm your name?' in r[0]['text']
      and 'Other users will see you as: *Rocky*' in r[0]['text'] and has_buttons(r[0], 'nm_yes', 'nm_no'),
      'Rocky picks 🎯 Partner → "Other users will see you as: *Rocky*. Is this correct?" [Yes] [No]')
check("Let's find you a partner" not in ''.join(m['text'] for m in r), '… and nothing else yet')
n = send(ROCKY, '🔥Rocky🔥 Singh', button='nm_no')
r = replies(ROCKY, n)
check(r and 'Please type the name' in r[0]['text'], 'No → "Please type the name you\'d like other users to see"')
n = send(ROCKY, '🔥Rocky🔥 Singh', 'ok')
r = replies(ROCKY, n)
check(r and "doesn't look like a name" in r[0]['text'], '"ok" → "that doesn\'t look like a name"')
n = send(ROCKY, '🔥Rocky🔥 Singh', 'my name is rohan')
r = replies(ROCKY, n, want=2)
check(r and 'Thank you, *Rohan*! ✅ Other users will see you as *Rohan*.' in r[0]['text'], '"my name is rohan" → "Thank you, Rohan"')
check(len(r) == 2 and "Let's find you a partner" in r[1]['text'], '… then the partner prompt he asked for, without asking again')
check(user(ROCKY) == 'Rohan|user', 'stored: Rohan, confirmed')
n = send(ROCKY, '🔥Rocky🔥 Singh', pick=PARTNER)
r = replies(ROCKY, n)
check(r and "Let's find you a partner" in r[0]['text'], 'next time: straight to the partner prompt')

# ── 2. A real name: Cab buddy → Yes → the trip form ──────────────────────────────────────────────
n = send(HARSH, 'Harsh Kharwar', pick=CAB)
r = replies(HARSH, n)
check(r and 'Before I look for a travel buddy' in r[0]['text'] and '*Harsh*' in r[0]['text'], 'Harsh picks 🚕 Cab buddy → "…see you as: *Harsh*"')
n = send(HARSH, 'Harsh Kharwar', button='nm_yes')
r = replies(HARSH, n, want=2)
check(r and r[0]['text'].startswith('Thank you, *Harsh*! ✅'), 'Yes → "Thank you, Harsh!"')
check(len(r) == 2 and (r[1].get('flow') or {}).get('flow_id') == 'mock-flow-1', '… then the trip form opens')
check(user(HARSH) == 'Harsh Kharwar|user', 'stored: Harsh Kharwar, confirmed')

# ── 3. Answering in words: "yes" typed instead of tapped (🤝 Connect) ────────────────────────────
n = send(MEERA, 'Meera', pick=CONNECT)
r = replies(MEERA, n)
check(r and 'Before I look for like-minded people' in r[0]['text'] and '*Meera*' in r[0]['text'], 'Meera picks 🤝 Connect → asked')
n = send(MEERA, 'Meera', 'Yes')
r = replies(MEERA, n, want=2)
check(len(r) == 2 and 'Thank you, *Meera*' in r[0]['text'] and 'ideal 1:1 partner' in r[1]['text'],
      '"Yes" typed → thanks, then the Connect questions')

# ── 4. Asked in words, no usable WhatsApp name: "May I know your name?" → the request is replayed ──
n = send(BUSY, 'Busy 24x7', 'I need a cab buddy from Indiranagar to Koramangala, Bangalore tomorrow 9 am', llm=True)
r = replies(BUSY, n)
check(r and 'Before I look for a travel buddy, may I know your name?' in r[0]['text'], '"Busy 24x7" asks for a cab buddy in words → "May I know your name?"')
n = send(BUSY, 'Busy 24x7', 'Kiran')
_last_llm[0] = time.time()             # the replay calls the LLM
r = replies(BUSY, n, want=2, timeout=90)
check(r and 'Thank you, *Kiran*!' in r[0]['text'], '"Kiran" → "Thank you, Kiran"')
check(len(r) >= 2 and 'confirm your name' not in r[1]['text'] and 'may I know your name' not in r[1]['text'],
      '… then the travel assistant picks up the same request')
check(user(BUSY) == 'Kiran|user', 'stored: Kiran, confirmed')

# ── 5. Onboarding (a partner request in words) asks the same: "No, change it" → typed → the age ──
n = send(COOL, 'Cool Dude', 'Badminton tomorrow 7 pm in HSR Layout, Bangalore', llm=True)
r = replies(COOL, n)
check(r and 'quick questions' in r[-1]['text'] and 'confirm your name' in r[-1]['text'] and '*Cool*' in r[-1]['text']
      and has_buttons(r[-1], 'pf_name_wa', 'pf_name_no'), 'onboarding: "Other users will see you as: *Cool*" [Yes] [No]')
n = send(COOL, 'Cool Dude', button='pf_name_no')
r = replies(COOL, n)
check(r and 'Please type the name' in r[0]['text'], 'No → "Please type the name"')
n = send(COOL, 'Cool Dude', 'Kabir')
r = replies(COOL, n)
check(r and 'Nice to meet you, Kabir! How old are you?' in r[0]['text'], '"Kabir" → "Nice to meet you, Kabir! How old are you?"')
check(user(COOL) == 'Kabir|user', 'stored: Kabir, confirmed')

print(f'\n{"FAILED: " + str(len(failures)) if failures else "all name checks passed"}')
for f in failures:
    print('  ✘', f)
sys.exit(1 if failures else 0)
