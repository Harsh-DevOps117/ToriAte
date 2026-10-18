import { rpc } from '@/lib/db';
import { checkWebhookSignature, notifyWhatsApp, settlePayment } from '@/lib/razorpay';
import { rupees } from '@/lib/wallet';

// POST /api/razorpay/webhook — set this URL (https://<board>/api/razorpay/webhook) and RAZORPAY_WEBHOOK_SECRET
// in Razorpay → Settings → Webhooks, events payment.captured, order.paid, payment.failed. The reliable
// path: the wallet is credited even if the person closed the tab. Every event is stored first (replays
// are ignored) and the signature is checked on the raw body.
export async function POST(req: Request) {
  const raw = await req.text();
  if (!checkWebhookSignature(raw, req.headers.get('x-razorpay-signature'))) {
    return Response.json({ error: 'signature' }, { status: 400 });
  }
  const body = JSON.parse(raw);
  const eventId = req.headers.get('x-razorpay-event-id') || `${body.event}:${body.payload?.payment?.entity?.id || body.created_at}`;
  const fresh = (await rpc<{ f: boolean }>('SELECT public.wallet_record_event($1, $2, $3::jsonb) AS f', [eventId, body.event, raw]))!.f;
  if (!fresh) return Response.json({ ok: true, duplicate: true });

  const p = body.payload?.payment?.entity;
  let result: unknown = { ignored: body.event };
  if ((body.event === 'payment.captured' || body.event === 'order.paid') && p?.order_id) {
    const r = await settlePayment(p.order_id, p.id, 'razorpay-webhook');
    if (r.state === 'credited') {
      await notifyWhatsApp(r.wa_id, `✅ ${rupees(r.amount_paise!)} added to your Tori Wallet. Balance: ${rupees(r.balance_paise!)}`);
    }
    result = r;
  } else if (body.event === 'payment.failed' && p?.order_id) {
    await rpc('SELECT public.wallet_fail_topup($1)', [p.order_id]);
    result = { failed: p.order_id };
  }
  await rpc('SELECT public.wallet_event_done($1, $2::jsonb)', [eventId, JSON.stringify(result)]);
  return Response.json({ ok: true });
}
