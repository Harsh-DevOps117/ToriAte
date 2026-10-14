import { getRequests, parseFilters } from '@/lib/board';

// GET /api/requests?activity=badminton&city=bangalore&when=tomorrow … — the same filters as the page, as JSON.
export async function GET(req: Request) {
  const filters = parseFilters(Object.fromEntries(new URL(req.url).searchParams));
  const { items, total } = await getRequests(filters);
  return Response.json({ total, items }, { headers: { 'cache-control': 'no-store' } });
}
