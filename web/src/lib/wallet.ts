import { cookies } from 'next/headers';
import { rpc } from './db';

export const SESSION_COOKIE = 'tori_wallet';
export type WalletUser = { user_id: string; name: string | null; phone: string; contact: string; balance_paise: number };
export type WalletRow = { at: string; kind: 'topup' | 'charge' | 'refund' | 'adjustment' | 'payee_payment' | 'payout_reversal' | 'referral'; amount_paise: number; memo: string; ref: string };

// The logged-in person (from the session cookie set by /wallet/login), or null
export async function currentUser(): Promise<WalletUser | null> {
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!token) return null;
  const r = await rpc<{ u: WalletUser | null }>('SELECT public.wallet_session_user($1) AS u', [token]);
  return r?.u ?? null;
}

export async function history(userId: string): Promise<WalletRow[]> {
  const r = await rpc<{ h: WalletRow[] }>('SELECT public.wallet_history($1::uuid, 50) AS h', [userId]);
  return r?.h ?? [];
}

export const rupees = (paise: number) =>
  '₹' + (paise / 100).toLocaleString('en-IN', { minimumFractionDigits: paise % 100 ? 2 : 0, maximumFractionDigits: 2 });
