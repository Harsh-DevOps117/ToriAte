import { cookies } from 'next/headers';
import { rpc } from '@/lib/db';
import { SESSION_COOKIE } from '@/lib/wallet';

export async function POST() {
  const store = await cookies();
  const token = store.get(SESSION_COOKIE)?.value;
  if (token) await rpc('SELECT public.wallet_end_session($1)', [token]);
  store.delete(SESSION_COOKIE);
  return new Response(null, { status: 303, headers: { location: '/wallet' } });
}
