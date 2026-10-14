#!/usr/bin/env python3
"""Profiles, cards and consent end to end: WhatsApp-shaped webhooks → workflow 06 (test copy) → Postgres.

Started by scripts/travel-e2e.sh (after the travel scenarios), which brings up an isolated stack with
real Groq, a mock WhatsApp API (with media downloads) and a mock geocoder. BOARD_PUBLIC_URL is
https://board.test there, so photo links can be checked without serving them.
"""
import json
import os
import re
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

P, Q, R, S = '919100000001', '919100000002', '919100000003', '919100000004'
H, J = '919100000005', '919100000006'


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


def send(wa, name, text=None, button=None, image=None, voice=None, msg_id=None, llm=None):
    """A text, a button tap, an image or a voice note from `wa`. Texts and voice notes call the LLM
    (paced) unless llm=False. Returns the reply count before."""
    if llm is None:
        llm = text is not None or voice is not None
    if llm:
        wait = _last_llm[0] + LLM_GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_llm[0] = time.time()
    _seq[0] += 1
    if button:
        m = {'type': 'interactive', 'interactive': {'type': 'button_reply', 'button_reply': {'id': button, 'title': 'x'}}}
    elif image:
        m = {'type': 'image', 'image': {'id': image, 'mime_type': 'image/jpeg', 'sha256': 'x'}}
    elif voice:
        m = {'type': 'audio', 'audio': {'id': voice, 'mime_type': 'audio/ogg; codecs=opus', 'voice': True}}
    else:
        m = {'type': 'text', 'text': {'body': text}}
    before = len(msgs(wa))
    http(N8N, {'messaging_product': 'whatsapp', 'metadata': {'phone_number_id': '100000000000002'},
               'contacts': [{'profile': {'name': name}, 'wa_id': wa}],
               'messages': [{'from': wa, 'id': msg_id or f'wamid.PROF{_seq[0]:04d}', 'timestamp': str(int(time.time())), **m}]})
    print(f'\n▶ {name} ({wa[-2:]}): {text or button or ("[photo " + str(image) + "]" if image else "[voice note " + str(voice) + "]")}')
    return before


def replies(wa, since, want=1, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        if len(msgs(wa)[since:]) >= want:
            time.sleep(2)  # let any follow-up message land too
            break
        time.sleep(1)
    got = msgs(wa)[since:]
    for g in got:
        extra = (f"   {[b['id'][:14] for b in g['buttons']]}" if g.get('buttons') else '') + (f"   🖼 {g['image']}" if g.get('image') else '')
        print(f'  ◀ to {wa[-2:]}: ' + g['text'].replace('\n', '\n             ') + extra)
    return got


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def last(r):
    return r[-1]['text'] if r else ''


def button(msg, prefix):
    return next((b['id'] for b in (msg or {}).get('buttons') or [] if b['id'].startswith(prefix)), None)


def state(wa):
    return psql(f"SELECT s.state FROM tori_conversation_state s JOIN tori_users u ON u.id = s.user_id WHERE u.phone = '+{wa}'")


def request_status(wa):
    return psql(f"SELECT string_agg(status, ',' ORDER BY created_at) FROM partner_requests WHERE wa_id = '{wa}'")


def onboard(wa, name, answers, r):
    """Answer the onboarding questions until "all set". answers: name/age/interests (text or 'button'),
    gender, social (text or None = Skip), photo (media id or None), about (text, 'voice:<id>' or None),
    privacy ('before' / 'after')."""
    for _ in range(10):
        t = last(r)
        if "all set" in t:
            return r
        n = None
        if "What's your name?" in t:
            n = send(wa, name, button='pf_name_wa') if answers.get('name') == 'button' else send(wa, name, answers['name'])
        elif 'How old' in t:
            n = send(wa, name, answers['age'])
        elif 'your gender' in t:
            n = send(wa, name, button='pf_gender_' + answers['gender'])
        elif 'like to play' in t:
            n = send(wa, name, answers['interests'])
        elif 'Instagram or LinkedIn' in t:
            n = send(wa, name, answers['social']) if answers.get('social') else send(wa, name, button='pf_skip_social')
        elif 'profile photo' in t or "couldn't use that photo" in t:
            n = send(wa, name, image=answers['photo']) if answers.get('photo') else send(wa, name, button='pf_skip_photo')
        elif 'Tell me a bit about yourself' in t or "couldn't make that out" in t:
            a = answers.get('about')
            n = (send(wa, name, voice=a[6:]) if a and a.startswith('voice:') else send(wa, name, a) if a
                 else send(wa, name, button='pf_skip_about'))
        elif 'Who can see' in t:
            n = send(wa, name, button='pf_priv_' + answers.get('privacy', 'after'))
        else:
            break
        r = replies(wa, n)
    return r


# ── 1. New user: the request is saved first, then one question at a time ───────────────────────
n = send(P, 'Pranav Rao', 'I want to find a partner for badminton tomorrow 7 pm in HSR Layout, Bangalore')
r = replies(P, n)
check('quick questions' in last(r) and "What's your name?" in last(r) and button(r[-1], 'pf_name_wa'),
      'P: asked for the name first, with a one-tap WhatsApp name')
check(request_status(P) == 'pending_profile' and state(P) == 'awaiting_profile', 'P: request parked, awaiting profile')

n = send(P, 'Pranav Rao', button='pf_name_wa')
r = replies(P, n)
check('Nice to meet you, Pranav' in last(r) and 'How old' in last(r), 'P: name confirmed → age')
n = send(P, 'Pranav Rao', '24')
r = replies(P, n)
check(button(r[-1], 'pf_gender_male'), 'P: age → gender buttons')
n = send(P, 'Pranav Rao', button='pf_gender_male')
r = replies(P, n)
check('like to play' in last(r), 'P: gender → interests')
n = send(P, 'Pranav Rao', 'badminton and football')
r = replies(P, n)
check('Instagram or LinkedIn' in last(r) and '*public*' in last(r) and button(r[-1], 'pf_skip_social'),
      'P: interests → optional link with Skip, and a note that Instagram must be public')
n = send(P, 'Pranav Rao', 'https://www.instagram.com/Pranav.R/?hl=en')
r = replies(P, n)
check('profile photo' in last(r), 'P: link saved → photo')
n = send(P, 'Pranav Rao', image='GIF1')
r = replies(P, n)
check("couldn't use that photo" in last(r), 'P: a GIF is refused')
n = send(P, 'Pranav Rao', image='MEDIA1')
r = replies(P, n)
check('Tell me a bit about yourself' in last(r) and 'voice note' in last(r) and button(r[-1], 'pf_skip_about'),
      'P: photo saved → "about you" (type it or a voice note, recommended)')
n = send(P, 'Pranav Rao', voice='VOICE1')
r = replies(P, n, timeout=90)
check("Here's what I'll share" in last(r) and 'badminton' in last(r).lower() and 'Who can see' in last(r)
      and button(r[-1], 'pf_priv_before'), 'P: voice note transcribed and summarised → privacy question')
check(psql(f"SELECT about_source || '|' || coalesce(skill_level, '-') || '|' || (about_text ILIKE '%badminton%') FROM tori_users WHERE phone = '+{P}'")
      == 'voice|intermediate|true', 'P: transcript saved, level "intermediate" read from the voice note')
n = send(P, 'Pranav Rao', button='pf_priv_before')
r = replies(P, n)
check("you're all set" in last(r) and 'badminton partner tomorrow' in last(r) and 'any match?' in last(r),
      'P: all set → request resumes, with the check-in tip')
check(request_status(P) == 'open' and state(P) == 'idle', 'P: request open, back to idle')
check(psql(f"SELECT social_url || '|' || (privacy ->> 'photo') || '|' || name_source FROM tori_users WHERE phone = '+{P}'")
      == 'https://instagram.com/pranav.r|before|user', 'P: link normalised, privacy "anyone I match with"')
check(psql(f"SELECT count(*) FROM tori_user_photos p JOIN tori_users u ON u.id = p.user_id WHERE u.phone = '+{P}'") == '1',
      'P: photo stored')
check(psql(f"SELECT lat IS NOT NULL FROM partner_requests WHERE wa_id = '{P}' AND status = 'open'") == 't', 'P: request geocoded')

# ── 2. Q posts 8:30 PM (90 min after P: inside the 2-hour window); profile in the same message ──
nq, np_ = len(msgs(Q)), len(msgs(P))
send(Q, '✨', "Hi I'm Priya, 27, female, I love badminton. Need a badminton partner tomorrow 8:30 pm in HSR Layout Bangalore")
r = replies(Q, nq)
check('quick questions' in last(r) and 'Instagram or LinkedIn' in last(r), 'Q: name, age, gender, interests taken from the message')
r = onboard(Q, '✨', {'social': None, 'photo': None}, r)
card = next((m for m in msgs(Q)[nq:] if button(m, 'pm_yes_')), None)
check(card is not None and 'Pranav' in card['text'] and 'Age:* 24' in card['text'] and 'instagram.com/pranav.r' in card['text']
      and (card.get('image') or '').startswith('https://board.test/p/'),
      'Q: Pranav\'s card with age, Instagram and photo (he allowed it before consent)')
check(card is not None and '*About:*' in card['text'] and 'Level:* intermediate' in card['text'], 'Q: the card has his "about" summary and level')
time.sleep(3)
check(not any(button(m, 'pm_yes_') for m in msgs(P)[np_:]), 'P: not asked yet (sequential consent)')

np_, nq = len(msgs(P)), len(msgs(Q))
send(Q, '✨', button=button(card, 'pm_yes_'))
rq = replies(Q, nq)
rp = replies(P, np_)
check("I've asked Pranav" in last(rq), 'Q: told Pranav is being asked')
pcard = next((m for m in rp if button(m, 'pm_yes_')), None)
check(pcard is not None and 'Priya' in pcard['text'] and 'Age:* 27' in pcard['text'] and not pcard.get('image'),
      'P: now gets Priya\'s card (no photo: she skipped it)')

np_, nq = len(msgs(P)), len(msgs(Q))
send(P, 'Pranav Rao', button=button(pcard, 'pm_yes_'))
rp, rq = replies(P, np_), replies(Q, nq)
check("It's a match" in last(rp) and f'wa.me/{Q}' in last(rp), 'P: connected, gets Priya\'s number')
check("It's a match" in last(rq) and f'wa.me/{P}' in last(rq) and 'instagram.com/pranav.r' in last(rq)
      and (rq[-1].get('image') or '').startswith('https://board.test/p/'), 'Q: connected, gets Pranav\'s number, Instagram and photo')

# ── 3. Incomplete request: after onboarding, the request question ───────────────────────────────
n = send(R, 'Riya', 'find me a tennis partner')
r = replies(R, n)
check("What's your name?" in last(r), 'R: onboarding starts with the name')
n = send(R, 'Riya', 'Riya, 26, female, tennis and yoga')
r = replies(R, n)
r = onboard(R, 'Riya', {'social': None, 'photo': None, 'about': 'Total beginner at tennis, free on weekend mornings, would love a patient partner'}, r)
check("you're all set" in last(r) and 'Now, about your request' in last(r), 'R: all set, then the request question')
check(any("Here's what I'll share" in m['text'] for m in msgs(R)), 'R: typed "about you" summarised')
check(psql(f"SELECT about_source || '|' || coalesce(skill_level, '-') FROM tori_users WHERE phone = '+{R}'") == 'text|beginner',
      'R: level "beginner" read from the typed text')
check(request_status(R) == 'draft', 'R: request is a draft again')

# ── 4. Cancel while onboarding ──────────────────────────────────────────────────────────────────
n = send(S, 'Sam', 'Football partner today 11 pm in Indiranagar, Bangalore')
replies(S, n)
n = send(S, 'Sam', 'stop looking, cancel it')
r = replies(S, n)
check('stopped looking' in last(r), 'S: cancel acknowledged')
check(request_status(S) == 'cancelled' and state(S) == 'idle', 'S: parked request cancelled, state idle')

# ── 5. Inbound log and redelivery ───────────────────────────────────────────────────────────────
n = send(S, 'Sam', 'hi', msg_id='wamid.PROF-DUP', llm=False)
replies(S, n)
time.sleep(4)
n1 = len(msgs(S))
send(S, 'Sam', 'hi', msg_id='wamid.PROF-DUP', llm=False)
time.sleep(8)
check(n1 > n and len(msgs(S)) == n1, 'S: menu sent once, the redelivery gets nothing')
check(psql("SELECT count(*) FROM tori_messages WHERE wa_message_id = 'wamid.PROF-DUP'") == '1', 'redelivery logged once')
check(int(psql(f"SELECT count(*) FROM tori_messages m JOIN tori_users u ON u.id = m.user_id WHERE u.phone = '+{P}' AND direction = 'in'")) >= 9,
      'P: every inbound message logged')

# ── 6. Someone outside WhatsApp's 24-hour window: asked when they check in ──────────────────────
n = send(H, 'Hema', 'badminton partner tomorrow 6 pm in Koramangala, Bangalore')
r = replies(H, n)
r = onboard(H, 'Hema', {'name': 'button', 'age': '25', 'gender': 'female', 'interests': 'badminton', 'social': None, 'photo': None}, r)
check('any match?' in last(r), 'H: the ack says to check in with "any match?"')
psql(f"UPDATE partner_requests SET last_message_at = now() - interval '30 hours' WHERE wa_id = '{H}'")  # H went quiet

nh, nj = len(msgs(H)), len(msgs(J))
send(J, 'Jay', "I'm Jay, 28, male, love badminton. Badminton partner tomorrow 6:30 pm in Koramangala, Bangalore")
r = replies(J, nj)
r = onboard(J, 'Jay', {'social': None, 'photo': None}, r)
card = next((m for m in msgs(J)[nj:] if button(m, 'pm_yes_')), None)
check(card is not None and 'Hema' in card['text'], 'J: gets Hema\'s card')
n = send(J, 'Jay', button=button(card, 'pm_yes_'))
r = replies(J, n)
check('saved it for them' in last(r) and 'any match?' in last(r), 'J: told Hema will see it when she checks in')
time.sleep(3)
check(len(msgs(H)) == nh, 'H: nothing sent while outside the window')
check(psql(f"SELECT count(*) FROM tori_held_messages WHERE wa_id = '{H}' AND delivered_at IS NULL") == '1', 'H: the card is kept')

n = send(H, 'Hema', 'any match?')
r = replies(H, n, want=2)
offer = next((m for m in r if button(m, 'pm_yes_')), None)
check(offer is not None and 'Jay' in offer['text'], 'H: gets Jay\'s card on "any match?"')
check(any('wants to play' in m['text'] for m in r), 'H: status reply says Jay wants to play')
nh, nj = len(msgs(H)), len(msgs(J))
send(H, 'Hema', button=button(offer, 'pm_yes_'))
rh, rj = replies(H, nh), replies(J, nj)
check("It's a match" in last(rh) and f'wa.me/{J}' in last(rh), 'H: connected with J')
check("It's a match" in last(rj) and f'wa.me/{H}' in last(rj), 'J: connected with H')

print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
sys.exit(1 if failures else 0)
