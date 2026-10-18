import { currentUser, history } from '@/lib/wallet';

// GET /api/wallet: the logged-in person's balance and last 50 movements
export async function GET() {
  const user = await currentUser();
  if (!user) return Response.json({ error: 'login' }, { status: 401 });
  return Response.json({ user: { name: user.name, phone: user.phone, balance_paise: user.balance_paise }, history: await history(user.user_id) },
                       { headers: { 'cache-control': 'no-store' } });
}
