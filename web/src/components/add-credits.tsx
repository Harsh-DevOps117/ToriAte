'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { CheckCircle2, CreditCard } from 'lucide-react';
import { btn, inputClass } from './ui';

declare global {
  interface Window { Razorpay?: new (options: Record<string, unknown>) => { open: () => void; on: (e: string, f: (r: unknown) => void) => void } }
}

const PACKS = [200, 500, 1000, 2000];
const ERRORS: Record<string, string> = {
  too_small: 'The minimum is ₹100.',
  too_big: 'The maximum per top-up is ₹10,000.',
  over_limit: 'Your wallet can hold up to ₹10,000.',
  login: 'Your session ended. Open the link from WhatsApp again.',
};

function loadCheckout(): Promise<void> {
  if (window.Razorpay) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://checkout.razorpay.com/v1/checkout.js';
    s.onload = () => resolve();
    s.onerror = () => reject(new Error('Could not load Razorpay'));
    document.body.appendChild(s);
  });
}

// Pick an amount → our server creates a Razorpay order → Checkout (UPI / card / netbanking) → our server
// checks the signature and the payment with Razorpay → credits are added once.
export function AddCredits() {
  const router = useRouter();
  const [amount, setAmount] = useState(500);
  const [custom, setCustom] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const rupees = custom ? Number(custom) : amount;

  async function pay() {
    setMsg(null);
    if (!Number.isFinite(rupees) || rupees <= 0) return setMsg({ ok: false, text: 'Enter an amount.' });
    setBusy(true);
    try {
      const res = await fetch('/api/wallet/topups', { method: 'POST', headers: { 'content-type': 'application/json' },
                                                      body: JSON.stringify({ amount_paise: Math.round(rupees * 100) }) });
      const order = await res.json();
      if (!res.ok) throw new Error(ERRORS[order.error] || 'Could not start the payment. Please try again.');
      await loadCheckout();
      const rzp = new window.Razorpay!({
        key: order.key_id, amount: order.amount, currency: 'INR', order_id: order.order_id,
        name: 'Tori', description: `Tori Wallet · ₹${rupees.toLocaleString('en-IN')} credits`,
        prefill: order.prefill, theme: { color: '#181d26' },
        handler: async (r: Record<string, string>) => {
          const v = await fetch('/api/wallet/topups/verify', { method: 'POST', headers: { 'content-type': 'application/json' },
                                                               body: JSON.stringify(r) });
          const out = await v.json().catch(() => ({}));
          setBusy(false);
          if (v.ok) {
            setMsg({ ok: true, text: `₹${rupees.toLocaleString('en-IN')} added to your wallet.` });
            setCustom('');
            router.refresh();
          } else {
            setMsg({ ok: false, text: out.state === 'not_captured' ? 'Payment received, finishing up… refresh in a minute.'
                                                                  : 'We could not confirm that payment. If money left your account, it will be added or refunded automatically.' });
          }
        },
        modal: { ondismiss: () => setBusy(false) },
      });
      rzp.on('payment.failed', () => { setBusy(false); setMsg({ ok: false, text: 'The payment failed. No money was taken.' }); });
      rzp.open();
    } catch (e) {
      setBusy(false);
      setMsg({ ok: false, text: (e as Error).message });
    }
  }

  return (
    <section className="flex flex-col gap-5 rounded-lg border border-hairline bg-canvas p-6">
      <h2 className="text-title-md font-medium">Add credits</h2>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4" role="group" aria-label="Amount">
        {PACKS.map((p) => (
          <button key={p} type="button" onClick={() => { setAmount(p); setCustom(''); }} aria-pressed={!custom && amount === p}
            className={`rounded-lg border px-4 py-4 text-left transition-colors ${!custom && amount === p ? 'border-primary bg-primary text-on-primary' : 'border-hairline bg-canvas text-ink hover:bg-surface-soft'}`}>
            <span className="block font-display text-title-md">₹{p.toLocaleString('en-IN')}</span>
            <span className={`text-caption ${!custom && amount === p ? 'text-on-primary/80' : 'text-muted'}`}>{p.toLocaleString('en-IN')} credits</span>
          </button>
        ))}
      </div>
      <label className="flex flex-col gap-1.5">
        <span className="text-caption font-medium text-muted">Or another amount (₹100 – ₹10,000)</span>
        <input className={inputClass} inputMode="numeric" placeholder="₹" value={custom}
               onChange={(e) => setCustom(e.target.value.replace(/[^\d]/g, '').slice(0, 5))} />
      </label>
      <button type="button" onClick={pay} disabled={busy} className={btn('primary', 'md', 'w-full sm:w-auto sm:self-start')}>
        <CreditCard className="size-5" aria-hidden />{busy ? 'Opening Razorpay…' : `Pay ₹${(rupees || 0).toLocaleString('en-IN')}`}
      </button>
      {msg && (
        <p role="status" className={`flex items-center gap-2 rounded-md px-3 py-2 text-body ${msg.ok ? 'bg-sig-mint text-ink' : 'bg-sig-peach text-ink'}`}>
          {msg.ok && <CheckCircle2 className="size-4" aria-hidden />}{msg.text}
        </p>
      )}
      <p className="text-caption text-muted">1 credit = ₹1. Paid securely through Razorpay (UPI, cards, netbanking). Tori never sees your card details.</p>
    </section>
  );
}
