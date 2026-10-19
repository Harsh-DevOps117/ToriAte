import { executePayout } from '@/lib/payout';
import { isBot } from '@/lib/razorpayx';

// POST /api/payouts/execute { payment_id } — the bot calls this right after "Pay ✅" (x-tori-key = WALLET_API_KEY)
export async function POST(req: Request) {
  if (!isBot(req)) return Response.json({ error: 'key' }, { status: 401 });
  const body = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/.test(String(body?.payment_id || ''))) return Response.json({ error: 'payment_id' }, { status: 400 });
  return Response.json(await executePayout(body.payment_id));
}
