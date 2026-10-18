#!/usr/bin/env python3
"""Tori Wallet end to end over HTTP: WhatsApp link → session → Razorpay top-up → credited once.

Started by scripts/wallet-e2e.sh: a scratch Postgres, the mock server (fake Razorpay) and the web app,
all on localhost. Checks login, limits, the Checkout callback (signature + capture), webhook replays,
a webhook-only top-up (tab closed), one-tap charges and the ledger invariants.
"""
import hashlib
import hmac
import http.cookiejar
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

WEB = os.environ['WALLET_E2E_WEB']
MOCK = os.environ['WALLET_E2E_MOCK']
PG = os.environ['WALLET_E2E_PG']                    # docker container name
KEY_SECRET = os.environ['RAZORPAY_KEY_SECRET']
WEBHOOK_SECRET = os.environ['RAZORPAY_WEBHOOK_SECRET']
WA = '919800000001'
failures = []


def check(cond, label):
    print(('  ✔ ' if cond else '  ✘ ') + label)
    if not cond:
        failures.append(label)


def psql(q):
    return subprocess.check_output(['docker', 'exec', PG, 'psql', '-U', 'tori_app', '-d', 'tori', '-tAc', q], text=True).strip()


jar = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)


def req(method, url, body=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(url, data=data, method=method,
                               headers={'content-type': 'application/json', **(headers or {})})
    try:
        with opener.open(r, timeout=30) as resp:
            text = resp.read().decode()
            return resp.status, (json.loads(text) if text.startswith(('{', '[')) else text), resp.headers
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        return e.code, (json.loads(text) if text.startswith(('{', '[')) else text), e.headers


sign = lambda key, data: hmac.new(key.encode(), data.encode(), hashlib.sha256).hexdigest()  # noqa: E731


def webhook(event, payment, signature=None):
    raw = json.dumps({'event': event, 'payload': {'payment': {'entity': payment}}, 'created_at': 1}).encode()
    return req('POST', WEB + '/api/razorpay/webhook', raw=raw,
               headers={'x-razorpay-signature': signature or sign(WEBHOOK_SECRET, raw.decode()),
                        'x-razorpay-event-id': 'evt_' + payment['id'] + '_' + event})


# ── 1. login from the WhatsApp link ─────────────────────────────────────────────────────────────
s, _, _ = req('GET', WEB + '/api/wallet')
check(s == 401, 'no session: the API refuses')
token = json.loads(psql(f"SELECT public.wallet_issue_link('{WA}', 'Asha Rao')"))['token']
s, _, h = req('GET', WEB + f'/wallet/login?t={token}')
check(s == 303 and h.get('location') == '/wallet' and 'tori_wallet=' in (h.get('set-cookie') or ''), 'link → session cookie → /wallet')
s, _, h = req('GET', WEB + f'/wallet/login?t={token}')
check(s == 303 and 'expired' in h.get('location', ''), 'the same link a second time: expired')
s, w, _ = req('GET', WEB + '/api/wallet')
check(s == 200 and w['user']['balance_paise'] == 0 and w['user']['name'] == 'Asha', 'wallet: ₹0 for Asha')

# ── 2. limits ───────────────────────────────────────────────────────────────────────────────────
s, r, _ = req('POST', WEB + '/api/wallet/topups', {'amount_paise': 5000})
check(s == 422 and r.get('error') == 'too_small', 'under ₹100 refused')

# ── 3. Checkout → callback (authorised only: our server captures) → credited once ─────────────
s, o, _ = req('POST', WEB + '/api/wallet/topups', {'amount_paise': 50000})
check(s == 200 and o['order_id'].startswith('order_') and o['amount'] == 50000 and o['prefill']['contact'] == '+' + WA,
      'top-up order created, contact prefilled')
s, pay, _ = req('POST', MOCK + '/_razorpay/pay', {'order_id': o['order_id'], 'capture': False})
cb = {'razorpay_order_id': o['order_id'], 'razorpay_payment_id': pay['id'],
      'razorpay_signature': sign(KEY_SECRET, f"{o['order_id']}|{pay['id']}")}
s, r, _ = req('POST', WEB + '/api/wallet/topups/verify', {**cb, 'razorpay_signature': 'f' * 64})
check(s == 400, 'a forged Checkout signature is refused')
s, r, _ = req('POST', WEB + '/api/wallet/topups/verify', cb)
check(s == 200 and r['state'] == 'credited' and r['balance_paise'] == 50000, 'callback: payment captured and ₹500 credited')
s, r, _ = req('POST', WEB + '/api/wallet/topups/verify', cb)
check(s == 200 and r['state'] == 'already', 'the same callback again: nothing more')
s, _, _ = webhook('payment.captured', {**pay, 'status': 'captured'})
check(s == 200, 'the webhook for it arrives')
s, w, _ = req('GET', WEB + '/api/wallet')
check(w['user']['balance_paise'] == 50000, 'still ₹500: credited exactly once')

# ── 4. tab closed: only the webhook ─────────────────────────────────────────────────────────────
s, o2, _ = req('POST', WEB + '/api/wallet/topups', {'amount_paise': 30000})
s, pay2, _ = req('POST', MOCK + '/_razorpay/pay', {'order_id': o2['order_id']})
s, _, _ = webhook('payment.captured', pay2, signature='0' * 64)
check(s == 400, 'a webhook with a bad signature is refused')
s, _, _ = webhook('payment.captured', pay2)
s, w, _ = req('GET', WEB + '/api/wallet')
check(w['user']['balance_paise'] == 80000, 'webhook alone credits ₹300 (tab was closed)')
s, r, _ = webhook('payment.captured', pay2)
check(r.get('duplicate') is True, 'a replayed webhook is ignored')

# ── 5. amount tampering: Razorpay says ₹1, our order was ₹200 ──────────────────────────────────
s, o3, _ = req('POST', WEB + '/api/wallet/topups', {'amount_paise': 20000})
s, pay3, _ = req('POST', MOCK + '/_razorpay/pay', {'order_id': o3['order_id'], 'amount': 100})
s, r, _ = req('POST', WEB + '/api/wallet/topups/verify', {'razorpay_order_id': o3['order_id'], 'razorpay_payment_id': pay3['id'],
                                                           'razorpay_signature': sign(KEY_SECRET, f"{o3['order_id']}|{pay3['id']}")})
check(s == 409 and r['state'] == 'mismatch', 'a payment for a different amount is not credited')

# ── 6. one-tap charge, history, page, invariants ────────────────────────────────────────────────
c = json.loads(psql(f"SELECT public.wallet_create_charge('{WA}', 35000, 'Court 2, Smash Arena · Sat 7 PM', 'b-1', 'e2e')"))
r = json.loads(psql(f"SELECT public.wallet_pay_charge('{c['charge_id']}', '{WA}')"))
check(r['state'] == 'paid' and r['balance_paise'] == 45000, 'one tap: ₹350 paid, ₹450 left')
s, w, _ = req('GET', WEB + '/api/wallet')
check([x['kind'] for x in w['history']] == ['charge', 'topup', 'topup'], 'history: charge, top-up, top-up')
s, html, _ = req('GET', WEB + '/wallet')
check(s == 200 and '₹450' in html and 'Court 2, Smash Arena' in html, 'the wallet page shows ₹450 and the booking')
check(json.loads(psql('SELECT public.wallet_check()')) == {'negative_wallets': 0, 'unbalanced_journals': 0}, 'ledger invariants hold')
s, _, _ = req('POST', WEB + '/wallet/logout')
s, _, _ = req('GET', WEB + '/api/wallet')
check(s == 401, 'logged out')

print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
sys.exit(1 if failures else 0)
