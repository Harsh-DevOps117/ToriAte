import { rpc } from '@/lib/db';
import { notifyWhatsApp } from '@/lib/razorpay';
import { checkPayoutWebhookSignature, paymentIdFromReference } from '@/lib/razorpayx';
import { rupees } from '@/lib/wallet';

type Settled = { state: string; payee?: string; amount_paise?: number; wa_id?: string; balance_paise?: number };

// POST /api/razorpayx/webhook — RazorpayX → Settings → Webhooks, events payout.processed, payout.failed,
// payout.reversed, payout.rejected; secret RAZORPAYX_WEBHOOK_SECRET (or RAZORPAY_WEBHOOK_SECRET).
// processed: the payee has the money. failed / reversed / rejected: the person gets it all back.
export async function POST(req: Request) {
  const raw = await req.text();
  if (!checkPayoutWebhookSignature(raw, req.headers.get('x-razorpay-signature'))) {
    return Response.json({ error: 'signature' }, { status: 400 });
  }
  const body = JSON.parse(raw);
  const p = body.payload?.payout?.entity;
  const eventId = req.headers.get('x-razorpay-event-id') || `${body.event}:${p?.id || body.created_at}`;
  const fresh = (await rpc<{ f: boolean }>('SELECT public.wallet_record_event($1, $2, $3::jsonb) AS f', [eventId, body.event, raw]))!.f;
  if (!fresh) return Response.json({ ok: true, duplicate: true });

  const event = String(body.event || '').replace(/^payout\./, '');
  let result: unknown = { ignored: body.event };
  if (p?.id && ['processed', 'failed', 'reversed', 'rejected'].includes(event)) {
    const reason = p.status_details?.description || p.failure_reason || null;
    let r = (await rpc<{ r: Settled }>('SELECT public.payout_settled($1, $2, $3) AS r', [p.id, event, reason]))!.r;
    const paymentId = paymentIdFromReference(p.reference_id);
    if (r.state === 'unknown' && paymentId) {      // the webhook beat our own payout_mark
      await rpc('SELECT public.payout_mark($1::uuid, $2)', [paymentId, p.id]);
      r = (await rpc<{ r: Settled }>('SELECT public.payout_settled($1, $2, $3) AS r', [p.id, event, reason]))!.r;
    }
    if (r.state === 'refunded') {
      await notifyWhatsApp(r.wa_id, `↩️ Your payment of ${rupees(r.amount_paise!)} to ${r.payee} didn't go through, so it's back in your Tori Wallet. Balance: ${rupees(r.balance_paise!)}`);
    }
    result = r;
  }
  await rpc('SELECT public.wallet_event_done($1, $2::jsonb)', [eventId, JSON.stringify(result)]);
  return Response.json({ ok: true });
}
