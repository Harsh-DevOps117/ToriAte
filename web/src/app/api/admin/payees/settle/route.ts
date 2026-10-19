import { rpc } from '@/lib/db';
import { isAdmin } from '@/lib/razorpayx';

// POST /api/admin/payees/settle { handle, reference } — the team paid the business by bank transfer: mark all it was owed settled
export async function POST(req: Request) {
  if (!isAdmin(req)) return Response.json({ error: 'key' }, { status: 401 });
  const b = await req.json().catch(() => ({}));
  if (!b?.handle || !b?.reference) return Response.json({ error: 'handle, reference' }, { status: 400 });
  const r = await rpc<{ r: unknown }>('SELECT public.payee_settle_manual($1, $2, $3) AS r', [b.handle, 'admin:api', String(b.reference)]);
  return Response.json(r!.r);
}
