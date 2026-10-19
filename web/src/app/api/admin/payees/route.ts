import { rpc } from '@/lib/db';
import { contactsConfigured, createFundAccount, isAdmin } from '@/lib/razorpayx';

// POST /api/admin/payees (x-tori-admin = TORI_ADMIN_KEY) — the team adds or changes a business people can pay.
// { handle, display_name, category, city?, area?, aliases?, owner_wa?, account_holder, ifsc, account_number?,
//   account_last4?, commission_bps?, status? }. A new account_number makes a RazorpayX fund account and is
// then dropped: only its last 4 digits are kept. Without one, the bank details on file stay as they are
// (send account_last4 + ifsc as they are now).
export async function POST(req: Request) {
  if (!isAdmin(req)) return Response.json({ error: 'key' }, { status: 401 });
  const b = await req.json().catch(() => null);
  if (!b || typeof b !== 'object') return Response.json({ error: 'body' }, { status: 400 });
  const ifsc = String(b.ifsc || '').toUpperCase().trim();
  const account = String(b.account_number || '').replace(/\s/g, '');
  if (!/^[A-Z]{4}0[A-Z0-9]{6}$/.test(ifsc)) return Response.json({ error: 'ifsc' }, { status: 400 });
  if (account && !/^\d{9,18}$/.test(account)) return Response.json({ error: 'account_number' }, { status: 400 });
  if (!account && !/^\d{4}$/.test(String(b.account_last4 || ''))) return Response.json({ error: 'account_number or account_last4' }, { status: 400 });
  if (!b.handle || !b.display_name || !b.account_holder) return Response.json({ error: 'handle, display_name, account_holder' }, { status: 400 });

  let rzp: { contact_id?: string; fund_account_id?: string } = {};
  if (account && contactsConfigured()) {
    try {
      rzp = await createFundAccount({ handle: String(b.handle), name: String(b.display_name), holder: String(b.account_holder),
                                      ifsc, account, phone: b.owner_wa ? String(b.owner_wa) : undefined });
    } catch (e) {
      return Response.json({ error: 'razorpayx', detail: (e as Error).message }, { status: 502 });
    }
  }
  const p = { handle: b.handle, display_name: b.display_name, category: b.category, city: b.city, area: b.area,
              aliases: Array.isArray(b.aliases) ? b.aliases : [], owner_wa: b.owner_wa, account_holder: b.account_holder,
              account_last4: account ? account.slice(-4) : String(b.account_last4), ifsc,
              rzp_contact_id: rzp.contact_id, rzp_fund_account_id: rzp.fund_account_id,
              commission_bps: b.commission_bps, status: b.status };
  try {
    const r = await rpc<{ r: unknown }>('SELECT public.payee_upsert($1::jsonb, $2) AS r', [JSON.stringify(p), 'admin:api']);
    return Response.json(r!.r);
  } catch (e) {
    return Response.json({ error: 'invalid', detail: (e as Error).message }, { status: 422 });
  }
}

// GET /api/admin/payees?q=gym — search, as the bot does
export async function GET(req: Request) {
  if (!isAdmin(req)) return Response.json({ error: 'key' }, { status: 401 });
  const q = new URL(req.url).searchParams.get('q') || '';
  return Response.json((await rpc<{ r: unknown }>('SELECT public.payee_search($1, 10) AS r', [q]))!.r);
}
