import { rpc } from './db';
import { createPayout, payoutsConfigured } from './razorpayx';

type Details = { payment_id: string; status: string; net_paise: number; fund_account_id: string | null; payee: string; reference: string };

// Send what a ToriPay payment owes the payee. Only a 'paid' payment with a fund account is sent; anything
// else (RazorpayX off, no fund account, API error) leaves it owed for the team. Safe to call twice.
export async function executePayout(paymentId: string) {
  const d = (await rpc<{ r: Details | null }>('SELECT public.payout_details($1::uuid) AS r', [paymentId]))?.r;
  if (!d) return { state: 'unknown' };
  if (d.status !== 'paid') return { state: d.status };
  if (!payoutsConfigured() || !d.fund_account_id) return { state: 'owed', reason: payoutsConfigured() ? 'no fund account' : 'payouts off' };
  try {
    const p = await createPayout(d.fund_account_id, d.net_paise, d.reference, `Tori ${d.payee}`);
    await rpc('SELECT public.payout_mark($1::uuid, $2)', [paymentId, p.id]);
    return { state: 'processing', payout_id: p.id, status: p.status };
  } catch (e) {
    console.error('payout', paymentId, (e as Error).message);
    return { state: 'owed', reason: 'payout error' };
  }
}
