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
import urllib.error
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
K, L, M, N, O = '919100000007', '919100000008', '919100000009', '919100000010', '919100000011'


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
        if 'confirm your name' in t or 'May I know your name' in t:
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
check('quick questions' in last(r) and 'confirm your name' in last(r) and '*Pranav*' in last(r)
      and button(r[-1], 'pf_name_wa') and button(r[-1], 'pf_name_no'),
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
check('confirm your name' in last(r), 'R: onboarding starts with the name')
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

# ── 7. Joining a game from the board: "JOIN <code>" → the host accepts or declines ──────────────
SKIP = {'social': None, 'photo': None, 'about': None}
n = send(K, 'Kavya', 'Football tomorrow 6 pm in Indiranagar, Bangalore, need 2 more players')
r = replies(K, n)
r = onboard(K, 'Kavya', {'name': 'button', 'age': '26', 'gender': 'female', 'interests': 'football', **SKIP}, r)
check('2 spots' in last(r) and 'spots 3' in last(r), 'K: the ack says 2 spots and how to change them')
code = psql(f"SELECT join_code FROM partner_requests WHERE wa_id = '{K}' AND status = 'open'")
check(len(code) == 4, f'K: the game has a join code ({code})')

# L is new: onboarding first, then the join goes to Kavya
nk = len(msgs(K))
n = send(L, 'Lata', f'JOIN {code}', llm=False)
r = replies(L, n)
check('Before I send your request to join' in last(r), 'L: JOIN from a new number starts onboarding first')
r = onboard(L, 'Lata', {'name': 'Lata, 24, female, football and running', **SKIP}, r)
r = replies(L, n, want=len(msgs(L)) - n + 1, timeout=20) if 'asked Kavya' not in ''.join(m['text'] for m in msgs(L)[n:]) else r
check(any("I've asked Kavya" in m['text'] for m in msgs(L)[n:]), 'L: profile done → join request sent to Kavya')
kc = next((m for m in msgs(K)[nk:] if button(m, 'pj_yes_')), None)
check(kc is not None and 'Lata' in kc['text'] and 'wants to join' in kc['text'] and '0/2' in kc['text'],
      'K: gets Lata\'s card with Accept / Decline (0/2 joined)')

nk, nl = len(msgs(K)), len(msgs(L))
send(K, 'Kavya', button=button(kc, 'pj_yes_'))
rk, rl = replies(K, nk), replies(L, nl)
check('Lata is in' in last(rk) and '1/2' in last(rk) and f'wa.me/{L}' in last(rk), 'K: Lata is in (1/2), with her number')
check('Kavya said yes' in last(rl) and f'wa.me/{K}' in last(rl), 'L: accepted, with Kavya\'s number')
check(psql(f"SELECT array_to_string(joined_names, ',') || '|' || board_status FROM v_partner_board WHERE join_code = '{code}'") == 'Lata|looking',
      'board: Lata joined, still looking')

# M joins, Kavya declines
n = send(M, 'Mohan', f'JOIN {code}', llm=False)
# the LLM sometimes reads "football" here as the game, not an interest: then it's asked for
r = onboard(M, 'Mohan', {'name': 'Mohan, 31, male, football', 'interests': 'football', **SKIP}, replies(M, n))
nk = len(msgs(K))
time.sleep(4)
kc = next((m for m in reversed(msgs(K)) if button(m, 'pj_no_') and 'Mohan' in m['text']), None)
check(kc is not None, 'K: gets Mohan\'s card')
nm = len(msgs(M))
send(K, 'Kavya', button=button(kc, 'pj_no_'))
rm = replies(M, nm)
check("can't take you" in last(rm), 'M: told Kavya declined')

# "spots 3", N joins and is accepted, "spots 2" → full; O hears it's full
n = send(K, 'Kavya', 'spots 3')
r = replies(K, n)
check('Up to 3 people' in last(r) and '1 joined' in last(r), 'K: "spots 3" changes the spots')
n = send(N, 'Nisha', f'JOIN {code}', llm=False)
r = onboard(N, 'Nisha', {'name': 'Nisha, 27, female, football', **SKIP}, replies(N, n))
time.sleep(4)
kc = next((m for m in reversed(msgs(K)) if button(m, 'pj_yes_') and 'Nisha' in m['text']), None)
nk = len(msgs(K))
send(K, 'Kavya', button=button(kc, 'pj_yes_'))
rk = replies(K, nk)
check('Nisha is in' in last(rk) and '2/3' in last(rk), 'K: Nisha is in (2/3)')
n = send(K, 'Kavya', 'spots 2')
r = replies(K, n)
check('full now' in last(r), 'K: "spots 2" with 2 in → full')
check(psql(f"SELECT array_to_string(joined_names, ',') || '|' || board_status FROM v_partner_board WHERE join_code = '{code}'")
      == 'Lata,Nisha|matched', 'board: Full, Lata and Nisha')
n = send(O, 'Om', f'JOIN {code}', llm=False)
r = replies(O, n)
check('full now' in last(r), 'O: told the game is full (no onboarding needed for that)')

n = send(K, 'Kavya', 'any match?')
r = replies(K, n)
check('full' in last(r) and 'Lata, Nisha' in last(r), 'K: status shows the game is full, with who joined')

# ── 8. A voice note works like typing: transcribed, then handled as text ────────────────────────
n = send(P, 'Pranav Rao', voice='VOICEREQ1')
r = replies(P, n, timeout=90)
check(any('badminton partner tomorrow' in m['text'] and 'HSR Layout' in m['text'] for m in r),
      'P: a spoken request ("badminton partner tomorrow 7 PM in HSR Layout") is acked like a typed one')
check(psql("SELECT count(*) FROM tori_messages WHERE wa_message_id LIKE '%.voice' AND body ILIKE '%badminton%'") == '1',
      'P: the transcript is logged as a text message from Pranav')

# ── 9. Tori Wallet: "add credits" link, one-tap checkout from a booking, demo charge ─────────────
n = send(P, 'Pranav Rao', 'add credits', llm=False)
r = replies(P, n)
check('Tori Wallet' in last(r) and re.search(r'https://board\.test/wallet/login\?t=[0-9a-f]{64}', last(r)) is not None,
      'P: "add credits" → balance and a one-time wallet link')
tok = re.search(r't=([0-9a-f]{64})', last(r)).group(1)
check(psql(f"SELECT public.wallet_open_session('{tok}') IS NOT NULL") == 't', 'the link opens a wallet session')

def charge(body, key='e2e-wallet-key'):
    rq = urllib.request.Request(N8N.replace('/wa-test', '/wallet/charge'), data=json.dumps(body).encode(), method='POST',
                                headers={'content-type': 'application/json', 'x-tori-key': key})
    try:
        with urllib.request.urlopen(rq, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, {}

st, _ = charge({'wa_id': P, 'amount_paise': 30000, 'description': 'Court 2, Smash Arena · Sat 7 PM', 'ref': 'b-1', 'source': 'e2e'}, key='nope')
check(st == 401, 'charge webhook: a wrong key is refused')
n = len(msgs(P))
st, ch = charge({'wa_id': P, 'amount_paise': 30000, 'description': 'Court 2, Smash Arena · Sat 7 PM', 'ref': 'b-1', 'source': 'e2e'})
r = replies(P, n)
pay_btn = button(r[-1] if r else None, 'wp_yes_')
check(st == 200 and ch.get('enough') is False and pay_btn and '₹300' in last(r) and 'wallet/login' in last(r),
      'booking asks for ₹300; wallet empty → [Pay ₹300] plus an add-credits link')
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('short' in last(r), 'P: tapping Pay with ₹0 → "₹300 short"')
psql("SELECT public.wallet_attach_order((public.wallet_create_topup((SELECT id FROM tori_users WHERE phone = '+919100000001'), 50000) ->> 'topup_id')::uuid, 'order_E2E')")
psql("SELECT public.wallet_credit_topup('order_E2E', 'pay_E2E', 50000, 'e2e')")
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('Paid ₹300' in last(r) and '₹200' in last(r), 'P: after adding ₹500, one tap pays ₹300 → ₹200 left')
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('Already paid' in last(r), 'P: a second tap charges nothing')
n = send(P, 'Pranav Rao', 'test booking 150', llm=False)
r = replies(P, n)
demo = r[-1] if r else {}
check(button(demo, 'wp_yes_') and '₹150' in demo.get('text', '') and '₹200 → ₹50' in demo.get('text', ''),
      'P: "test booking 150" (demo) → [Pay ₹150], ₹200 → ₹50')
n = send(P, 'Pranav Rao', button=button(demo, 'wp_no_'))
r = replies(P, n)
check('cancelled' in last(r) and psql("SELECT public.wallet_balance((SELECT id FROM tori_users WHERE phone = '+919100000001'))") == '20000',
      'P: Cancel → nothing taken, still ₹200')

# ── 10. ToriPay: "tori pay gym 150" → choose the gym → one tap; "gym edit"; "my payees" ───────────
OWNER = '919100000020'
psql("""SELECT public.payee_upsert('{"handle": "fitzone-hsr", "display_name": "FitZone Gym", "category": "gym", "area": "HSR Layout",
        "owner_wa": "919100000020", "account_holder": "FITZONE FITNESS", "account_last4": "1234", "ifsc": "HDFC0001234",
        "rzp_fund_account_id": "fa_E2E"}', 'e2e')""")
psql("""SELECT public.payee_upsert('{"handle": "zen-gym", "display_name": "Zen Gym", "category": "gym", "area": "Indiranagar",
        "account_holder": "ZEN GYM", "account_last4": "9876", "ifsc": "ICIC0004321"}', 'e2e')""")
n = send(P, 'Pranav Rao', 'tori pay gym 150', llm=False)
r = replies(P, n)
pick = next((b['id'] for b in (r[-1] if r else {}).get('buttons') or [] if b['title'] == 'FitZone Gym'), None)
check(pick and pick.startswith('tps_') and 'Zen Gym' in last(r), 'P: "tori pay gym 150" → a list of the two gyms')
n = send(P, 'Pranav Rao', button=pick)
r = replies(P, n)
pay_btn = button(r[-1] if r else None, 'tp_yes_')
check(pay_btn and 'FitZone Gym' in last(r) and 'HDFC ••1234' in last(r) and '₹200 → ₹50' in last(r),
      'P: picked FitZone → bank shown, [Pay ₹150], ₹200 → ₹50')
o = len(msgs(OWNER))
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('Paid ₹150 to *FitZone Gym*' in last(r) and 'tori pay gym 150' in last(r), 'P: one tap → paid, and the shortcut is offered')
r = replies(OWNER, o)
check('Pranav paid ₹150' in last(r), 'the owner hears about it')
time.sleep(2)
check(psql(f"SELECT status FROM payee_payments WHERE id = '{pay_btn[len('tp_yes_'):]}'") == 'paid',
      'the web app has it: owed to FitZone (RazorpayX payouts off in tests)')
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('Already paid' in last(r), 'P: a second tap pays nothing')
n = send(P, 'Pranav Rao', 'tori pay gym 500', llm=False)
r = replies(P, n)
check(button(r[-1] if r else None, 'tp_no_') and 'FitZone' in last(r) and 'wallet/login' in last(r),
      'P: "tori pay gym 500" → straight to FitZone (shortcut); ₹50 → an add-credits link')
n = send(P, 'Pranav Rao', button=button(r[-1], 'tp_no_'))
r = replies(P, n)
check('cancelled' in last(r), 'P: Cancel')
n = send(P, 'Pranav Rao', 'gym edit', llm=False)
r = replies(P, n)
zen = next((b['id'] for b in (r[-1] if r else {}).get('buttons') or [] if b['title'] == 'Zen Gym'), None)
check(zen and zen.startswith('tpe_') and 'pays *FitZone Gym*' in last(r), 'P: "gym edit" → currently FitZone, pick another')
n = send(P, 'Pranav Rao', button=zen)
r = replies(P, n)
check('*gym* now pays *Zen Gym*' in last(r), 'P: "gym" now pays Zen Gym')
n = send(P, 'Pranav Rao', 'my payees', llm=False)
r = replies(P, n)
check('*gym* → *Zen Gym*' in last(r) and '₹50' in last(r), 'P: "my payees" → gym → Zen Gym, wallet ₹50')

# ── 11. ToriPay: a coach Tori doesn't know → added with the bank details, then paid ─────────────
psql("SELECT public.wallet_attach_order((public.wallet_create_topup((SELECT id FROM tori_users WHERE phone = '+919100000001'), 50000) ->> 'topup_id')::uuid, 'order_E2E2')")
psql("SELECT public.wallet_credit_topup('order_E2E2', 'pay_E2E2', 50000, 'e2e')")      # ₹550
n = send(P, 'Pranav Rao', 'tori pay coach 300', llm=False)
r = replies(P, n)
check("don't have your *coach* yet" in last(r), 'P: "tori pay coach 300" → not on Tori → "what is it called?"')
n = send(P, 'Pranav Rao', 'Rahul Badminton Academy', llm=False)
r = replies(P, n)
check('IFSC' in last(r), 'P: name → asks for the IFSC')
n = send(P, 'Pranav Rao', 'HDFC0999999', llm=False)
r = replies(P, n)
check("couldn't find that IFSC" in last(r), 'P: an IFSC that does not exist → asked again')
n = send(P, 'Pranav Rao', 'hdfc0001234', llm=False)
r = replies(P, n)
check('HDFC Bank, HSR LAYOUT' in last(r) and 'holder' in last(r), 'P: IFSC → bank and branch shown → holder name')
n = send(P, 'Pranav Rao', 'Rahul Sharma', llm=False)
r = replies(P, n)
check('account number' in last(r), 'P: holder → account number')
n = send(P, 'Pranav Rao', '5010 0123 4567 89', llm=False)
r = replies(P, n)
check('once more' in last(r), 'P: account number → type it once more')
n = send(P, 'Pranav Rao', '50100123456780', llm=False)
r = replies(P, n)
check("don't match" in last(r), 'P: a different second number → start that step again')
n = send(P, 'Pranav Rao', '50100123456789', llm=False)
replies(P, n)
n = send(P, 'Pranav Rao', '50100123456789', llm=False)
r = replies(P, n, want=2)
pay_btn = button(r[-1] if r else None, 'tp_yes_')
check(any('Saved *Rahul Badminton Academy* as your *coach*' in x['text'] for x in r) and pay_btn and '••6789' in last(r)
      and 'added by you' in last(r) and '₹550 → ₹250' in last(r), 'P: numbers match → saved, then [Pay ₹300] with HDFC ••6789')
x = http(MOCK + '/_razorpay/state')
check(any(f['bank_account']['account_number'] == '50100123456789' and f['bank_account']['name'] == 'RAHUL SHARMA'
          for f in x['fund_accounts'].values()), 'RazorpayX got the account')
check(psql("SELECT count(*) FROM tori_messages WHERE body LIKE '%50100123456789%' OR body LIKE '%5010 0123%'") == '0'
      and psql("SELECT count(*) FROM payees WHERE row_to_json(payees)::text LIKE '%50100123456789%'") == '0'
      and psql("SELECT count(*) FROM tori_messages WHERE body = '[bank account number]'") == '4',
      'the account number is in no Tori table (the message log says "[bank account number]")')
n = send(P, 'Pranav Rao', button=pay_btn)
r = replies(P, n)
check('Paid ₹300 to *Rahul Badminton Academy*' in last(r), 'P: one tap → paid')
n = send(P, 'Pranav Rao', 'coach edit', llm=False)
r = replies(P, n)
fix = button(r[-1] if r else None, 'tpa_fix_')
check(fix and 'Someone else' in last(r), 'P: "coach edit" → [Change bank details] [Someone else]')
n = send(P, 'Pranav Rao', button=fix)
r = replies(P, n)
check('update your *coach*' in last(r) and 'same' in last(r), 'P: change bank details → starts with the name')
n = send(P, 'Pranav Rao', 'cancel', llm=False)
r = replies(P, n)
check('Nothing was saved' in last(r), 'P: cancel → stopped')
n = send(P, 'Pranav Rao', 'tori pay coach 100', llm=False)
r = replies(P, n)
check('Rahul Badminton Academy' in last(r) and button(r[-1] if r else None, 'tp_yes_'), 'P: the coach shortcut works straight away')
check(psql("SELECT public.wallet_check()") == '{"negative_wallets": 0, "unbalanced_journals": 0}', 'ledger invariants hold')

print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
sys.exit(1 if failures else 0)
