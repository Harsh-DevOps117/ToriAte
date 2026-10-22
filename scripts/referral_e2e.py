#!/usr/bin/env python3
"""Referrals end to end: WhatsApp-shaped webhooks → workflow 06 (test copy) → Postgres → mock WhatsApp.

Started by scripts/travel-e2e.sh (E2E_ONLY=referral runs just this), in its throwaway stack:
BOARD_WHATSAPP_NUMBER is 15550001111 there. Nothing here calls the LLM, so it takes about a minute.
"""
import concurrent.futures
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
failures = []
_seq = [0]

ASHA, BINA, CHIRAG, DEV, ESHA, FARAH = (f'91920000000{i}' for i in range(1, 7))


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


def send(wa, name, text, msg_id=None, quiet=False):
    _seq[0] += 1
    http(N8N, {'messaging_product': 'whatsapp', 'metadata': {'phone_number_id': '100000000000002'},
               'contacts': [{'profile': {'name': name}, 'wa_id': wa}],
               'messages': [{'from': wa, 'id': msg_id or f'wamid.REF{_seq[0]:04d}', 'timestamp': str(int(time.time())),
                             'type': 'text', 'text': {'body': text}}]})
    if not quiet:
        print(f'\n▶ {name} ({wa[-2:]}): {text}')


def replies(wa, since, want=1, timeout=45, settle=3):
    end = time.time() + timeout
    while time.time() < end and len(msgs(wa)[since:]) < want:
        time.sleep(1)
    time.sleep(settle)  # let any follow-up message land too
    got = msgs(wa)[since:]
    for g in got:
        print(f'  ◀ to {wa[-2:]}: ' + g['text'].replace('\n', '\n             '))
    return got


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def bal(wa):
    return int(psql(f"SELECT public.wallet_balance(id) FROM tori_users WHERE phone = '+{wa}'") or 0)


def texts(r):
    return '\n---\n'.join(m['text'] for m in r)


# ── 1. "invite": the code, how it works, and a message to forward ────────────────────────────────
n = len(msgs(ASHA))
send(ASHA, 'Asha Rao', 'invite')
r = replies(ASHA, n, want=2)
code = (re.search(r'TORI-[A-HJKMNP-Z2-9]{6}', texts(r)) or [None])[0]
check(len(r) == 2 and code and 'both' in r[0]['text'] and '30 credits' in r[0]['text'], 'Asha: "invite" → her code, both get 30 credits')
check(code and f'https://wa.me/15550001111?text=Hi%20Tori!%20%F0%9F%91%8B%20My%20invite%20code%20is%20{code}' in r[-1]['text'],
      'second message: a wa.me link that opens Tori with the code typed in')
n = len(msgs(ASHA))
send(ASHA, 'Asha Rao', 'Refer a friend')
r = replies(ASHA, n, want=2)
check(len(r) == 2 and code in r[0]['text'], '"Refer a friend" works too, same code')
# Asha has been on Tori for a month
psql(f"UPDATE tori_users SET created_at = now() - interval '30 days' WHERE phone = '+{ASHA}'")

# ── 2. A new friend opens the link: both wallets +30, a welcome and the menu, Asha is told ──────────
na, nb = len(msgs(ASHA)), len(msgs(BINA))
send(BINA, 'Bina Shah', f'Hi Tori! 👋 My invite code is {code}', msg_id='wamid.REF-BINA-1')
rb = replies(BINA, nb, want=2)
ra = replies(ASHA, na, want=1)
check(rb and 'Welcome to Tori, Bina' in rb[0]['text'] and "Asha's invite" in rb[0]['text'] and '30 credits' in rb[0]['text'],
      'Bina: welcome, 30 credits from Asha\'s invite')
check(len(rb) == 2 and rb[1]['type'] == 'interactive' and 'Invite friends' in rb[1]['text'], 'Bina: then the services menu')
check(ra and 'Bina just joined Tori with your invite' in ra[0]['text'] and '+30 credits' in ra[0]['text'] and '₹30' in ra[0]['text'],
      'Asha: "Bina just joined", +30 credits, balance ₹30')
check(bal(ASHA) == 3000 and bal(BINA) == 3000, 'both wallets: 30 credits (₹30)')

# ── 3. Once per person: again, a redelivery, someone else's code ──────────────────────────────────
nb = len(msgs(BINA))
send(BINA, 'Bina Shah', f'Hi Tori! 👋 My invite code is {code}', msg_id='wamid.REF-BINA-1')   # Meta redelivers
time.sleep(6)
check(len(msgs(BINA)) == nb, 'a redelivered message is ignored')
send(BINA, 'Bina Shah', f'my code {code}')
r = replies(BINA, nb)
check(r and 'already got your invite bonus' in r[0]['text'], 'the code again → "already got your bonus"')
check(bal(ASHA) == 3000 and bal(BINA) == 3000, 'nobody was credited twice')

# ── 4. Codes that don't count ────────────────────────────────────────────────────────────────────
bina_code = json.loads(psql(f"SELECT public.referral_invite('{BINA}')"))['code']
na = len(msgs(ASHA))
send(ASHA, 'Asha Rao', bina_code)
r = replies(ASHA, na)
check(r and 'new to Tori' in r[0]['text'] and bal(ASHA) == 3000, "Asha (a month on Tori) can't use Bina's code")
na = len(msgs(ASHA))
send(ASHA, 'Asha Rao', f'Hi Tori! 👋 My invite code is {code.lower()}')
r = replies(ASHA, na)
check(r and 'your own invite code' in r[0]['text'], 'her own code → "that\'s your own code"')
nc = len(msgs(CHIRAG))
send(CHIRAG, 'Chirag', 'Hi Tori! 👋 My invite code is TORI-ZZZZZZ')
r = replies(CHIRAG, nc, want=2)
check(r and "couldn't find the invite code TORI-ZZZZZZ" in r[0]['text'] and len(r) == 2 and r[1]['type'] == 'interactive',
      'unknown code → "couldn\'t find it", then the menu')
check(bal(CHIRAG) == 0, 'Chirag: nothing credited')

# ── 5. A referrer outside the 24-hour window: the news waits for their next message ────────────────
dev_code = json.loads(psql(f"SELECT public.referral_invite('{DEV}', 'Dev')"))['code']
psql(f"INSERT INTO tori_messages (user_id, direction, type, body, created_at) "
     f"SELECT id, 'in', 'text', 'hi', now() - interval '2 days' FROM tori_users WHERE phone = '+{DEV}'")
nd, ne = len(msgs(DEV)), len(msgs(ESHA))
send(ESHA, 'Esha', f'Hi Tori! 👋 My invite code is {dev_code}')
re_ = replies(ESHA, ne, want=2)
check(re_ and "Dev's invite" in re_[0]['text'], 'Esha: welcome with Dev\'s invite')
time.sleep(3)
check(len(msgs(DEV)) == nd and bal(DEV) == 3000, 'Dev (quiet for 2 days): credited, but not messaged yet')
send(DEV, 'Dev', 'balance')
r = replies(DEV, nd, want=2)
check(any('Esha just joined Tori with your invite' in m['text'] for m in r), 'Dev writes → the kept "Esha joined" arrives')
check(any('Tori Wallet' in m['text'] and '₹30' in m['text'] for m in r), '… with his wallet reply (₹30)')

# ── 6. The same new person sends the code 8 times at once: credited once ─────────────────────────
before = bal(ASHA)
with concurrent.futures.ThreadPoolExecutor(8) as ex:
    list(ex.map(lambda i: send(FARAH, 'Farah', f'Hi Tori! 👋 My invite code is {code}', msg_id=f'wamid.REF-FARAH-{i}', quiet=True),
                range(8)))
print(f'\n▶ Farah ({FARAH[-2:]}): the invite message, 8 times at once')
time.sleep(12)
check(bal(FARAH) == 3000 and bal(ASHA) == before + 3000, 'Farah +30 and Asha +30, once')
check(psql(f"SELECT count(*) FROM referrals WHERE referee_id = (SELECT id FROM tori_users WHERE phone = '+{FARAH}')") == '1',
      'one referral row')
check(sum('Welcome to Tori' in m['text'] for m in msgs(FARAH)) == 1, 'one welcome')

# ── 7. The ledger ────────────────────────────────────────────────────────────────────────────────
check(psql("SELECT public.wallet_check()") == '{"negative_wallets": 0, "unbalanced_journals": 0}', 'ledger invariants hold')
check(psql("SELECT -sum(amount_paise) FROM wallet_postings WHERE account = 'tori:referrals'") == '18000',
      'Tori paid ₹180 in referral bonuses (3 friends × 2 people × ₹30)')

print(f'\n{"FAILED: " + str(len(failures)) if failures else "all referral checks passed"}')
for f in failures:
    print('  ✘', f)
sys.exit(1 if failures else 0)
