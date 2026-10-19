import { rpc } from '@/lib/db';
import { isAdmin } from '@/lib/razorpayx';

// GET /api/admin/payees/owed — what Tori owes each business (paid by people, not yet in the business's bank)
export async function GET(req: Request) {
  if (!isAdmin(req)) return Response.json({ error: 'key' }, { status: 401 });
  return Response.json((await rpc<{ r: unknown }>('SELECT public.payees_owed() AS r'))!.r);
}
