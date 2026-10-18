import { checkPaymentSignature, notifyWhatsApp, settlePayment } from '@/lib/razorpay';
import { currentUser, rupees } from '@/lib/wallet';

// POST /api/wallet/topups/verify — what Checkout's handler returns. The signature proves the payment is
// Razorpay's for this order; settlePayment then asks Razorpay for the real amount and status and credits
// the wallet once (the webhook does the same, whichever comes first).
export async function POST(req: Request) {
  const user = await currentUser();
  if (!user) return Response.json({ error: 'login' }, { status: 401 });
  const b = await req.json().catch(() => ({}));
  const order = String(b?.razorpay_order_id || '');
  const payment = String(b?.razorpay_payment_id || '');
  if (!checkPaymentSignature(order, payment, String(b?.razorpay_signature || ''))) {
    return Response.json({ error: 'signature' }, { status: 400 });
  }
  const r = await settlePayment(order, payment, 'web');
  if (r.state === 'credited') {
    await notifyWhatsApp(r.wa_id, `✅ ${rupees(r.amount_paise!)} added to your Tori Wallet. Balance: ${rupees(r.balance_paise!)}`);
  }
  return Response.json(r, { status: r.state === 'credited' || r.state === 'already' ? 200 : 409 });
}
