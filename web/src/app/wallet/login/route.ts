import { cookies } from 'next/headers';
import { rpc } from '@/lib/db';
import { SESSION_COOKIE } from '@/lib/wallet';

// GET /wallet/login?t=<one-time token>: the link the bot sends for "add credits". A valid, unused link
// (15 minutes) becomes a 30-day session cookie. Redirects are relative, so they work behind the tunnel.
export async function GET(req: Request) {
  const url = new URL(req.url);
  const token = url.searchParams.get('t') || '';
  const r = /^[0-9a-f]{64}$/.test(token) ? await rpc<{ s: string | null }>('SELECT public.wallet_open_session($1) AS s', [token]) : null;
  if (!r?.s) return new Response(null, { status: 303, headers: { location: '/wallet?link=expired' } });
  const https = (req.headers.get('x-forwarded-proto') || url.protocol.replace(':', '')) === 'https';
  (await cookies()).set(SESSION_COOKIE, r.s, { httpOnly: true, sameSite: 'lax', secure: https, path: '/', maxAge: 30 * 86400 });
  return new Response(null, { status: 303, headers: { location: '/wallet' } });
}
