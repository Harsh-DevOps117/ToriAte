#!/usr/bin/env python3
"""Tori Wallet end to end over HTTP: WhatsApp link → session → Razorpay top-up → credited once.

Started by scripts/wallet-e2e.sh: a scratch Postgres, the mock server (fake Razorpay) and the web app,
all on localhost. Checks login, limits, the Checkout callback (signature + capture), webhook replays,
a webhook-only top-up (tab closed), one-tap charges, ToriPay payouts (RazorpayX) and the ledger invariants.
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
BOT = {'x-tori-key': os.environ['WALLET_API_KEY']}
ADMIN = {'x-tori-admin': os.environ['TORI_ADMIN_KEY']}
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

# ── 7. ToriPay: the team adds a gym, a payment goes out through RazorpayX ───────────────────────
def payout_webhook(event, payout):
    raw = json.dumps({'event': event, 'payload': {'payout': {'entity': payout}}, 'created_at': 2}).encode()
    return req('POST', WEB + '/api/razorpayx/webhook', raw=raw,
               headers={'x-razorpay-signature': sign(WEBHOOK_SECRET, raw.decode()), 'x-razorpay-event-id': 'evt_' + payout['id'] + '_' + event})


def toripay(handle, paise):
    pid = psql(f"SELECT id FROM payees WHERE handle = '{handle}'")
    start = json.loads(psql(f"SELECT public.toripay_start('{WA}', '{pid}', {paise}, NULL)"))
    return json.loads(psql(f"SELECT public.toripay_confirm('{start['payment_id']}', '{WA}')"))


uid = psql(f"SELECT id FROM tori_users WHERE phone = '+{WA}'")
t = json.loads(psql(f"SELECT public.wallet_create_topup('{uid}', 100000)"))
psql(f"SELECT public.wallet_attach_order('{t['topup_id']}', 'order_tp1')")
psql("SELECT public.wallet_credit_topup('order_tp1', 'pay_tp1', 100000, 'e2e')")      # ₹1,450 in the wallet

GYM = {'handle': 'fitzone-hsr', 'display_name': 'FitZone Gym', 'category': 'gym', 'area': 'HSR Layout', 'aliases': ['fitzone'],
       'owner_wa': '+91 98765 00001', 'account_holder': 'FITZONE FITNESS', 'ifsc': 'HDFC0001234',
       'account_number': '50100123451234', 'commission_bps': 100}
s, r, _ = req('POST', WEB + '/api/admin/payees', GYM)
check(s == 401, 'adding a business needs the admin key')
s, r, _ = req('POST', WEB + '/api/admin/payees', GYM, headers=BOT)
check(s == 401, "the bot's key is not the admin key")
s, r, _ = req('POST', WEB + '/api/admin/payees', {**GYM, 'ifsc': 'HDFC123'}, headers=ADMIN)
check(s == 400 and r['error'] == 'ifsc', 'a bad IFSC is refused')
s, r, _ = req('POST', WEB + '/api/admin/payees', GYM, headers=ADMIN)
check(s == 200 and r['has_fund_account'] and r['last4'] == '1234' and r['bank'] == 'HDFC', 'FitZone added with a RazorpayX fund account')
x = req('GET', MOCK + '/_razorpay/state')[1]
check(any(f['bank_account']['account_number'] == GYM['account_number'] for f in x['fund_accounts'].values()),
      'RazorpayX got the account number')
check(psql("SELECT count(*) FROM payees p WHERE row_to_json(p)::text LIKE '%50100123451234%'") == '0', '…and Tori did not keep it')
s, r, _ = req('GET', WEB + '/api/admin/payees?q=fitzone', headers=ADMIN)
check(s == 200 and r[0]['handle'] == 'fitzone-hsr' and 'account_number' not in r[0], 'search finds it, no account number in it')

paid = toripay('fitzone-hsr', 20000)
check(paid['state'] == 'paid' and paid['net_paise'] == 19800, '₹200 paid from the wallet (₹198 to FitZone after 1 %)')
s, r, _ = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']})
check(s == 401, 'payout endpoint needs the bot key')
s, r, _ = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)
check(s == 200 and r['state'] == 'processing' and r['payout_id'].startswith('pout_'), 'payout sent to RazorpayX')
s, r2, _ = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)
x = req('GET', MOCK + '/_razorpay/state')[1]
check(r2['state'] == 'processing' and len(x['payouts']) == 1, 'asking twice sends one payout')
po = x['payouts'][r['payout_id']]
check(po['amount'] == 19800 and po['idempotency_key'] == po['reference_id'], '₹198, with an idempotency key')
s, r, _ = payout_webhook('payout.processed', {**po, 'status': 'processed'})
s, r, _ = payout_webhook('payout.processed', {**po, 'status': 'processed'})
check(r.get('duplicate') is True and psql(f"SELECT status FROM payee_payments WHERE id = '{paid['payment_id']}'") == 'settled',
      'payout.processed: settled (replay ignored)')

before = int(psql(f"SELECT public.wallet_balance(id) FROM tori_users WHERE phone = '+{WA}'"))
paid = toripay('fitzone-hsr', 10000)
po = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)[1]
s, r, _ = payout_webhook('payout.reversed', {'id': po['payout_id'], 'status': 'reversed', 'reference_id': 'x',
                                             'status_details': {'description': 'beneficiary bank offline'}})
check(int(psql(f"SELECT public.wallet_balance(id) FROM tori_users WHERE phone = '+{WA}'")) == before, 'payout.reversed: the ₹100 is back in the wallet')

paid = toripay('fitzone-hsr', 10000)                        # the webhook arrives before our own payout_mark
ref = 'toripay-' + paid['payment_id'].replace('-', '')
s, r, _ = payout_webhook('payout.processed', {'id': 'pout_early1', 'status': 'processed', 'reference_id': ref})
check(psql(f"SELECT status || ' ' || rzp_payout_id FROM payee_payments WHERE id = '{paid['payment_id']}'") == 'settled pout_early1',
      'a webhook that beats us is matched by its reference')

req('POST', MOCK + '/_faults', {'payout_fail_next': 1})
paid = toripay('fitzone-hsr', 10000)
r = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)[1]
check(r['state'] == 'owed', 'RazorpayX down: the payment stays owed')
r = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)[1]
check(r['state'] == 'processing', '…and goes out on a retry')

s, r, _ = req('POST', WEB + '/api/admin/payees', {'handle': 'green-turf', 'display_name': 'Green Turf', 'category': 'turf',
              'account_holder': 'GREEN TURF', 'ifsc': 'SBIN0000001', 'account_last4': '5555'}, headers=ADMIN)
check(s == 200 and not r['has_fund_account'], 'a business without a fund account (bank details on file only)')
paid = toripay('green-turf', 15000)
r = req('POST', WEB + '/api/payouts/execute', {'payment_id': paid['payment_id']}, headers=BOT)[1]
check(r['state'] == 'owed', 'no fund account: owed')
s, r, _ = req('GET', WEB + '/api/admin/payees/owed', headers=ADMIN)
check(s == 200 and any(o['handle'] == 'green-turf' and o['owed_paise'] == 15000 for o in r), 'owed report: Green Turf ₹150')
s, r, _ = req('POST', WEB + '/api/admin/payees/settle', {'handle': 'green-turf', 'reference': 'NEFT N123'}, headers=ADMIN)
check(s == 200 and r['settled_paise'] == 15000, 'settled by bank transfer')
s, r, _ = req('POST', WEB + '/api/toripay/answer', {'wa_id': WA, 'text': '50100123456789'})
check(s == 401, 'the add-a-payee endpoint needs the bot key')
s, r, _ = req('POST', WEB + '/api/toripay/answer', {'wa_id': WA, 'text': 'hello'}, headers=BOT)
check(s == 200 and r['kind'] == 'add_gone', 'no payee being added: nothing to answer')
check(json.loads(psql('SELECT public.wallet_check()')) == {'negative_wallets': 0, 'unbalanced_journals': 0}, 'ledger invariants hold after ToriPay')

print(f"\n{'ALL PASSED' if not failures else 'FAILED: ' + '; '.join(failures)}")
sys.exit(1 if failures else 0)
