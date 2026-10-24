import { rpc } from '@/lib/db';

// /api/graph/<path> — the bot's way to the WhatsApp Cloud API. n8n's BOT_WHATSAPP_GRAPH_URL points here
// (docker-compose.yml); every request is passed on to WHATSAPP_GRAPH_UPSTREAM unchanged, with one addition for
// sent messages (POST <phone number id>/messages):
// - each one is logged with its buttons (tori_log_bot_message), so the voice agent can say the bot's replies on a
//   call (/api/mcp message_tori) and the chat history is complete;
// - the first one after something was said on a call starts with it (📞 On your call: "…"), so the WhatsApp chat
//   reads as one conversation with the call.
// Logging never holds up or fails a send. Only for the bot inside the Docker network: requests that came through
// the public tunnel (Cloudflare headers) are refused.

const UPSTREAM = () => (process.env.WHATSAPP_GRAPH_UPSTREAM || 'https://graph.facebook.com/v19.0').replace(/\/+$/, '');

type Msg = {
  to?: string; type?: string;
  text?: { body?: string };
  image?: { caption?: string };
  interactive?: { body?: { text?: string }; action?: { buttons?: { reply?: { id?: string; title?: string } }[];
                                                        sections?: { rows?: { id?: string; title?: string }[] }[] } };
  template?: { name?: string };
};

// the words of a message, as the log and the voice agent see them
function words(m: Msg): string {
  if (m.type === 'text') return m.text?.body || '';
  if (m.type === 'image') return m.image?.caption || '';
  if (m.type === 'interactive') {
    const a = m.interactive?.action;
    const choices = [...(a?.buttons || []).map((b) => b.reply?.title), ...(a?.sections || []).flatMap((s) => (s.rows || []).map((r) => r.title))];
    return [m.interactive?.body?.text || '', choices.filter(Boolean).length ? `[${choices.filter(Boolean).join(' | ')}]` : ''].filter(Boolean).join('\n');
  }
  if (m.type === 'template') return `[template ${m.template?.name || ''}]`;
  return `[${m.type || 'message'}]`;
}

function withEcho(m: Msg, said: string): Msg {
  const head = `📞 _On your call: "${said.replace(/[_*]/g, '')}"_\n\n`;
  if (m.type === 'text' && m.text) return { ...m, text: { ...m.text, body: (head + (m.text.body || '')).slice(0, 4096) } };
  if (m.type === 'interactive' && m.interactive?.body) {
    return { ...m, interactive: { ...m.interactive, body: { text: (head + (m.interactive.body.text || '')).slice(0, 1024) } } };
  }
  if (m.type === 'image' && m.image) return { ...m, image: { ...m.image, caption: (head + (m.image.caption || '')).slice(0, 1024) } };
  return m;
}

async function forward(req: Request, ctx: { params: Promise<{ path: string[] }> }) {
  if (req.headers.has('cf-ray') || req.headers.has('cf-connecting-ip')) return new Response(null, { status: 404 });
  if (!req.headers.get('authorization')) return Response.json({ error: { message: 'no token' } }, { status: 401 });
  const { path } = await ctx.params;
  const url = UPSTREAM() + '/' + path.map(encodeURIComponent).join('/') + new URL(req.url).search;
  const type = req.headers.get('content-type') || '';
  let body: BodyInit | undefined = ['GET', 'HEAD'].includes(req.method) ? undefined : await req.arrayBuffer();
  let msg: Msg | null = null;

  if (req.method === 'POST' && path.at(-1) === 'messages' && type.includes('json') && body) {
    try {
      msg = JSON.parse(Buffer.from(body as ArrayBuffer).toString('utf8')) as Msg;
    } catch {
      msg = null;
    }
    if (msg?.to && /^\d{8,15}$/.test(msg.to)) {
      const echo = await rpc<{ said: string | null }>('SELECT public.tori_take_echo($1) AS said', [msg.to]).catch(() => null);
      if (echo?.said) {
        msg = withEcho(msg, echo.said);
        body = JSON.stringify(msg);
      }
    }
  }

  const headers: Record<string, string> = { authorization: req.headers.get('authorization')! };
  if (type) headers['content-type'] = type;
  // A network blip (the connection to Meta failed before the request went out) is tried again, twice: Meta never
  // got it, so nothing is sent twice. A timeout is not retried, as Meta may have the message already.
  let res: Response | undefined;
  for (let attempt = 1; !res; attempt++) {
    try {
      res = await fetch(url, { method: req.method, headers, body, cache: 'no-store', signal: AbortSignal.timeout(60000) });
    } catch (e) {
      const cause = ((e as Error & { cause?: { code?: string } }).cause?.code) || (e as Error).name;
      const before = ['ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'EAI_AGAIN', 'ENETUNREACH', 'EHOSTUNREACH',
                      'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_SOCKET'].includes(cause);
      console.error('graph', req.method, path.at(-1), (e as Error).message, cause, `attempt ${attempt}`);
      if (!before || attempt === 3) {
        return Response.json({ error: { message: 'WhatsApp API unreachable', code: 502 } }, { status: 502 });
      }
      await new Promise((r) => setTimeout(r, attempt * 1000));
    }
  }
  const out = await res.arrayBuffer();

  if (msg?.to && res.ok) {
    let id = '';
    try {
      id = (JSON.parse(Buffer.from(out).toString('utf8')) as { messages?: { id?: string }[] }).messages?.[0]?.id || '';
    } catch {}
    const { to, ...payload } = msg;
    rpc('SELECT public.tori_log_bot_message($1, $2, $3, $4, $5::jsonb)', [to, id, msg.type || '', words(msg), JSON.stringify(payload)])
      .catch((e) => console.error('outbox log', (e as Error).message));
  }
  return new Response(out, { status: res.status, headers: { 'content-type': res.headers.get('content-type') || 'application/json' } });
}

export const GET = forward;
export const POST = forward;
export const DELETE = forward;
