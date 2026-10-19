import crypto from 'node:crypto';

// RazorpayX (Contacts, Fund Accounts, Payouts) for ToriPay: money owed to a gym leaves Tori's RazorpayX
// account to the gym's bank. Same API keys as Razorpay; payouts also need RAZORPAYX_ACCOUNT_NUMBER (the
// RazorpayX current account money is sent from). Without it, payments stay owed in the ledger and the
// team settles them by hand (GET /api/admin/payees/owed). Docs: https://razorpay.com/docs/api/x/
const KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const ACCOUNT = process.env.RAZORPAYX_ACCOUNT_NUMBER || '';
const WEBHOOK_SECRET = process.env.RAZORPAYX_WEBHOOK_SECRET || process.env.RAZORPAY_WEBHOOK_SECRET || '';
const API = (process.env.RAZORPAYX_API_URL || process.env.RAZORPAY_API_URL || 'https://api.razorpay.com/v1').replace(/\/+$/, '');

export const contactsConfigured = () => !!(KEY_ID && SECRET);
export const payoutsConfigured = () => !!(KEY_ID && SECRET && ACCOUNT);

async function call<T>(path: string, body: unknown, headers: Record<string, string> = {}): Promise<T> {
  const res = await fetch(API + path, {
    method: 'POST',
    headers: { authorization: 'Basic ' + Buffer.from(`${KEY_ID}:${SECRET}`).toString('base64'),
               'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
    cache: 'no-store',
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`razorpayx POST ${path}: ${res.status} ${json?.error?.description || ''}`.trim());
  return json as T;
}

type Contact = { id: string };
type FundAccount = { id: string; bank_account?: { name?: string } };
export type Payout = { id: string; status: string; reference_id?: string };

// One contact + bank fund account per payee. The account number goes to RazorpayX and nowhere else.
export async function createFundAccount(p: { handle: string; name: string; holder: string; ifsc: string; account: string;
                                             phone?: string }) {
  const contact = await call<Contact>('/contacts', { name: p.name, type: 'vendor', reference_id: p.handle,
                                                     contact: p.phone || undefined, notes: { source: 'toripay' } });
  const fa = await call<FundAccount>('/fund_accounts', { contact_id: contact.id, account_type: 'bank_account',
                                                         bank_account: { name: p.holder, ifsc: p.ifsc, account_number: p.account } });
  return { contact_id: contact.id, fund_account_id: fa.id };
}

// The idempotency key is the payment's reference, so a retry never pays twice
export const createPayout = (fundAccountId: string, amountPaise: number, reference: string, narration: string) =>
  call<Payout>('/payouts', { account_number: ACCOUNT, fund_account_id: fundAccountId, amount: amountPaise, currency: 'INR',
                             mode: amountPaise >= 20000000 ? 'NEFT' : 'IMPS', purpose: 'vendor bill', queue_if_low_balance: true,
                             reference_id: reference, narration: narration.replace(/[^A-Za-z0-9 ]/g, '').slice(0, 30) },
               { 'X-Payout-Idempotency': reference });

export const paymentIdFromReference = (ref: string | undefined) => {
  const m = /^toripay-([0-9a-f]{32})$/.exec(ref || '');
  return m ? m[1].replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5') : null;
};

export function checkPayoutWebhookSignature(rawBody: string, signature: string | null) {
  if (!WEBHOOK_SECRET) return false;
  const x = Buffer.from(crypto.createHmac('sha256', WEBHOOK_SECRET).update(rawBody).digest('hex'));
  const y = Buffer.from(signature || '');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// The team's admin key, for the payee routes (x-tori-admin). Never the wallet key the bot holds.
export function isAdmin(req: Request) {
  const key = process.env.TORI_ADMIN_KEY || '';
  const got = Buffer.from(req.headers.get('x-tori-admin') || '');
  return !!key && got.length === Buffer.byteLength(key) && crypto.timingSafeEqual(got, Buffer.from(key));
}

export function isBot(req: Request) {
  const key = process.env.WALLET_API_KEY || '';
  const got = Buffer.from(req.headers.get('x-tori-key') || '');
  return !!key && got.length === Buffer.byteLength(key) && crypto.timingSafeEqual(got, Buffer.from(key));
}
