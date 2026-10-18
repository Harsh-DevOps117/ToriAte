import crypto from 'node:crypto';
import { rpc } from './db';

// Razorpay (Orders API + Checkout). Test-mode keys come from .env (RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET);
// the secret never leaves the server. Docs: https://razorpay.com/docs/api/orders/
const KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET || '';
const API = (process.env.RAZORPAY_API_URL || 'https://api.razorpay.com/v1').replace(/\/+$/, '');

export const razorpayKeyId = () => KEY_ID;
export const razorpayConfigured = () => !!(KEY_ID && SECRET);

async function call<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const res = await fetch(API + path, {
    method,
    headers: { authorization: 'Basic ' + Buffer.from(`${KEY_ID}:${SECRET}`).toString('base64'), 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: 'no-store',
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`razorpay ${method} ${path}: ${res.status} ${json?.error?.description || ''}`.trim());
  return json as T;
}

type Order = { id: string; amount: number; status: string };
type Payment = { id: string; order_id: string; amount: number; currency: string; status: string };

export const createOrder = (amountPaise: number, receipt: string, notes: Record<string, string>) =>
  call<Order>('POST', '/orders', { amount: amountPaise, currency: 'INR', receipt, notes });

const hmac = (key: string, data: string) => crypto.createHmac('sha256', key).update(data).digest('hex');
const same = (a: string, b: string) => {
  const x = Buffer.from(a || '');
  const y = Buffer.from(b || '');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

// Checkout's handler returns these three; the signature proves Razorpay made the payment for this order
export const checkPaymentSignature = (orderId: string, paymentId: string, signature: string) =>
  !!SECRET && same(hmac(SECRET, `${orderId}|${paymentId}`), signature);
export const checkWebhookSignature = (rawBody: string, signature: string | null) =>
  !!WEBHOOK_SECRET && same(hmac(WEBHOOK_SECRET, rawBody), signature || '');

export type Credit = { state: 'credited' | 'already' | 'mismatch' | 'unknown' | 'not_captured'; balance_paise?: number;
                       amount_paise?: number; wa_id?: string };

// Ask Razorpay what really happened (never trust the browser), capture it if only authorised, then credit
// the wallet. wallet_credit_topup is idempotent and checks the amount against our own top-up row.
export async function settlePayment(orderId: string, paymentId: string, by: string): Promise<Credit> {
  let p = await call<Payment>('GET', `/payments/${encodeURIComponent(paymentId)}`);
  if (p.order_id !== orderId || p.currency !== 'INR') return { state: 'mismatch' };
  if (p.status === 'authorized') {
    p = await call<Payment>('POST', `/payments/${encodeURIComponent(paymentId)}/capture`, { amount: p.amount, currency: 'INR' });
  }
  if (p.status !== 'captured') return { state: 'not_captured' };
  const r = await rpc<{ r: Credit }>('SELECT public.wallet_credit_topup($1, $2, $3, $4) AS r', [orderId, paymentId, p.amount, by]);
  return r!.r;
}

// "✅ ₹500 added" on WhatsApp, through workflow 06's notify webhook (best effort)
export async function notifyWhatsApp(waId: string | undefined, text: string) {
  const url = process.env.TORI_BOT_URL;
  if (!url || !waId || !process.env.WALLET_API_KEY) return;
  await fetch(url.replace(/\/+$/, '') + '/webhook/wallet/notify', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-tori-key': process.env.WALLET_API_KEY },
    body: JSON.stringify({ wa_id: waId, text }),
    cache: 'no-store',
  }).catch(() => {});
}
