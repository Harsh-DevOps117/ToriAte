import { rpc } from '@/lib/db';
import { createOrder, razorpayConfigured, razorpayKeyId } from '@/lib/razorpay';
import { currentUser } from '@/lib/wallet';

type Topup = { state: string; topup_id?: string; min_paise?: number; max_paise?: number; max_balance_paise?: number; balance_paise?: number };

// POST /api/wallet/topups { amount_paise } → a Razorpay order for Checkout. Limits are checked in SQL.
export async function POST(req: Request) {
  const user = await currentUser();
  if (!user) return Response.json({ error: 'login' }, { status: 401 });
  if (!razorpayConfigured()) return Response.json({ error: 'payments are not set up' }, { status: 503 });
  const body = await req.json().catch(() => ({}));
  const amount = Number(body?.amount_paise);
  if (!Number.isInteger(amount)) return Response.json({ error: 'amount' }, { status: 400 });

  const t = (await rpc<{ r: Topup }>('SELECT public.wallet_create_topup($1::uuid, $2) AS r', [user.user_id, amount]))!.r;
  if (t.state !== 'ok') return Response.json({ error: t.state, ...t }, { status: 422 });
  const order = await createOrder(amount, t.topup_id!, { topup_id: t.topup_id!, purpose: 'tori_wallet' });
  await rpc('SELECT public.wallet_attach_order($1::uuid, $2)', [t.topup_id, order.id]);
  return Response.json({ order_id: order.id, key_id: razorpayKeyId(), amount, currency: 'INR',
                         prefill: { contact: user.contact, name: user.name || '' } });
}
