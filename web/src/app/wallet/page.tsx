import Link from 'next/link';
import { ArrowDownLeft, ArrowUpRight, Gift, LogOut, MessageCircle, RotateCcw, Wallet } from 'lucide-react';
import { AddCredits } from '@/components/add-credits';
import { btn, Logo } from '@/components/ui';
import { botNumber } from '@/lib/board';
import { currentUser, history, rupees } from '@/lib/wallet';

export const metadata = { title: 'Wallet' };

const KIND = {
  topup: { label: 'Added credits', icon: ArrowDownLeft },
  charge: { label: 'Paid', icon: ArrowUpRight },
  refund: { label: 'Refund', icon: RotateCcw },
  adjustment: { label: 'Adjustment', icon: RotateCcw },
  payee_payment: { label: 'ToriPay', icon: ArrowUpRight },
  payout_reversal: { label: 'ToriPay refund', icon: RotateCcw },
  referral: { label: 'Invite bonus', icon: Gift },
} as const;

function when(iso: string) {
  return new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })
    .format(new Date(iso));
}

export default async function WalletPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const user = await currentUser();
  const rows = user ? await history(user.user_id) : [];
  const bot = botNumber();

  return (
    <div className="min-h-dvh bg-page">
      <nav className="sticky top-0 z-40 h-16 border-b border-ink/8 bg-page/85 backdrop-blur">
        <div className="mx-auto flex h-full max-w-3xl items-center justify-between gap-4 px-4 sm:px-8">
          <Link href="/" aria-label="Tori partner board"><Logo /></Link>
          {user && (
            <form action="/wallet/logout" method="post">
              <button className={btn('ghost', 'sm')}><LogOut className="size-4" aria-hidden />Log out</button>
            </form>
          )}
        </div>
      </nav>

      <main className="mx-auto flex max-w-3xl flex-col gap-8 px-4 py-10 sm:px-8">
        {!user ? (
          <section className="flex flex-col items-start gap-4 rounded-lg border border-hairline bg-canvas p-8">
            <Wallet className="size-8 text-ink" aria-hidden />
            <h1 className="font-display text-display-md font-normal">Tori Wallet</h1>
            <p className="max-w-lg text-body text-muted">
              {sp.link === 'expired' ? 'That link has expired or was already used. ' : ''}
              Open your wallet from WhatsApp: send <span className="font-medium text-ink">add credits</span> to Tori and tap the link
              it sends you. No password needed.
            </p>
            {bot && (
              <a href={`https://wa.me/${bot}?text=${encodeURIComponent('add credits')}`} target="_blank" rel="noopener noreferrer" className={btn('primary', 'sm')}>
                <MessageCircle className="size-4" aria-hidden />Open WhatsApp
              </a>
            )}
          </section>
        ) : (
          <>
            <header className="flex flex-col gap-1">
              <p className="text-body text-muted">{user.name ? `Hi ${user.name}` : 'Your wallet'} · {user.phone}</p>
              <h1 className="font-display text-display-md font-normal">Tori Wallet</h1>
            </header>

            <section className="flex flex-col gap-2 rounded-lg bg-surface-dark p-6 text-on-primary">
              <span className="text-caption text-on-primary/70">Balance</span>
              <span className="font-display text-display-lg">{rupees(user.balance_paise)}</span>
              <span className="text-caption text-on-primary/70">
                {(user.balance_paise / 100).toLocaleString('en-IN')} credits · book on WhatsApp and tap <b>Pay</b>: one tap, no payment page
              </span>
            </section>

            <AddCredits />

            {bot && (
              <section className="flex items-center gap-4 rounded-lg border border-hairline bg-canvas p-5">
                <Gift className="size-6 shrink-0 text-ink" aria-hidden />
                <p className="flex-1 text-body text-muted">
                  <span className="font-medium text-ink">Invite friends, get free credits.</span> When a friend joins Tori with your code, you both get credits.
                </p>
                <a href={`https://wa.me/${bot}?text=${encodeURIComponent('invite')}`} target="_blank" rel="noopener noreferrer" className={btn('secondary', 'sm')}>
                  Get my code
                </a>
              </section>
            )}

            <section className="flex flex-col gap-3">
              <h2 className="text-title-lg">History</h2>
              {rows.map((h, i) => {
                const k = KIND[h.kind] || KIND.adjustment;
                const Icon = k.icon;
                return (
                  <div key={i} className="flex items-center gap-4 border-t border-hairline py-3">
                    <span className={`inline-flex size-9 shrink-0 items-center justify-center rounded-full ${h.amount_paise > 0 ? 'bg-sig-mint' : 'bg-surface-strong'}`}>
                      <Icon className="size-4 text-ink" aria-hidden />
                    </span>
                    <div className="flex min-w-0 flex-1 flex-col">
                      <span className="truncate text-label font-medium text-ink">{h.kind === 'charge' || h.kind === 'payee_payment' || h.kind === 'payout_reversal' || h.kind === 'referral' ? h.memo : k.label}</span>
                      <span className="text-caption text-muted">{when(h.at)}{h.kind === 'topup' && h.ref ? ` · ${h.ref}` : ''}</span>
                    </div>
                    <span className={`shrink-0 text-label font-medium ${h.amount_paise > 0 ? 'text-success' : 'text-ink'}`}>
                      {h.amount_paise > 0 ? '+' : '−'}{rupees(Math.abs(h.amount_paise))}
                    </span>
                  </div>
                );
              })}
              {rows.length === 0 && <p className="text-body text-muted">No movements yet. Add credits to get started.</p>}
            </section>
          </>
        )}
      </main>
    </div>
  );
}
