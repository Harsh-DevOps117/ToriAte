import { rows } from '@/lib/db';

// GET /p/<token>: a profile photo, for WhatsApp to show as the image on a match card. The bot only puts a
// token into messages for a matched person, and only as that photo's owner allowed (db/migrations/009_*).
// Tokens are random UUIDs; a new photo gets a new token, so old links stop working.
export async function GET(_req: Request, ctx: { params: Promise<{ token: string }> }) {
  const { token } = await ctx.params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
    return new Response('Not found', { status: 404 });
  }
  const [photo] = await rows<{ mime: string; bytes: Buffer }>(
    'SELECT mime, bytes FROM public.tori_user_photos WHERE token = $1', [token]);
  if (!photo) return new Response('Not found', { status: 404 });
  return new Response(new Uint8Array(photo.bytes), {
    headers: {
      'content-type': photo.mime,
      'cache-control': 'private, max-age=3600',
      'x-robots-tag': 'noindex',
    },
  });
}
