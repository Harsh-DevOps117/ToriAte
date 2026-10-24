import crypto from 'node:crypto';
import { rows, rpc } from '@/lib/db';

// The Harsh AI voice agent (Vapi) acting for a caller, through the Tori MCP server (/api/mcp). One conversation
// with the WhatsApp bot: what the caller says on the call goes to the bot as their message, the bot's replies come
// back for the agent to say, and the same messages appear in their WhatsApp chat.

export type Caller = { wa_id: string; name: string | null };
export type Reply = { text: string; buttons?: { id: string; title: string }[] };

// Who is on the call. Vapi sends X-Call-Id with every MCP request. For a WhatsApp call, the voice-call log
// (db 015, filled by voice-bridge) links Vapi's call ID to the caller's number, which WhatsApp vouches for.
// Calls from the web page (/voice) are anonymous: null.
export async function callerFor(vapiCallId: string): Promise<Caller | null> {
  if (!/^[\w-]{8,64}$/.test(vapiCallId)) return null;
  const [c] = await rows<Caller>(`
    SELECT c.caller_wa_id AS wa_id, coalesce(u.name, c.caller_name) AS name
      FROM public.voice_calls c
      LEFT JOIN public.tori_users u ON u.phone = '+' || c.caller_wa_id
     WHERE c.vapi_call_id = $1 AND c.channel = 'whatsapp' AND c.caller_wa_id ~ '^\\d{8,15}$'
       AND c.state NOT IN ('failed', 'rejected')
       AND coalesce(c.ended_at, now()) > now() - interval '2 minutes'    -- live (or just hung up)
       AND c.started_at > now() - interval '3 hours'`, [vapiCallId]);
  return c ?? null;
}

// Hand something to the WhatsApp bot (workflow 06) as if the caller had typed it or tapped a button in their
// chat, signed the way Meta signs webhooks (the WhatsApp Trigger checks X-Hub-Signature-256). The bot runs its
// usual flow and replies in the chat; its first reply starts with what they said (agent_echo, /api/graph).
async function relay(c: Caller, m: { text?: string; button?: { id: string; title: string } }): Promise<boolean> {
  const url = process.env.TORI_BOT_INBOUND_URL || '';
  const secret = process.env.BOT_META_APP_SECRET || '';
  if (!url || !secret) return false;
  const base = { from: c.wa_id, id: `wamid.agent.${crypto.randomUUID()}`, timestamp: String(Math.floor(Date.now() / 1000)) };
  const message = m.button
    ? { ...base, type: 'interactive', interactive: { type: 'button_reply', button_reply: { id: m.button.id, title: m.button.title } } }
    : { ...base, type: 'text', text: { body: String(m.text || '').replace(/\s+/g, ' ').trim().slice(0, 500) } };
  const value = {
    messaging_product: 'whatsapp',
    metadata: { phone_number_id: process.env.BOT_WHATSAPP_PHONE_NUMBER_ID || '' },
    contacts: [{ profile: { name: c.name || '' }, wa_id: c.wa_id }],
    messages: [message],
  };
  const raw = JSON.stringify({ object: 'whatsapp_business_account', entry: [{ id: 'voice-agent', changes: [{ field: 'messages', value }] }] });
  const signature = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
  try {
    const res = await fetch(url, {
      method: 'POST', body: raw, cache: 'no-store', signal: AbortSignal.timeout(10000),
      headers: { 'content-type': 'application/json', 'x-hub-signature-256': signature },
    });
    return res.ok;
  } catch {
    return false;
  }
}

type Choice = { id?: string; title?: string };
type Payload = {
  type?: string; text?: { body?: string }; image?: { caption?: string };
  interactive?: { body?: { text?: string }; action?: { buttons?: { reply?: Choice }[]; sections?: { rows?: Choice[] }[] } };
};
type Sent = { at: string; payload: Payload | null; body: string };

// a logged bot message (/api/graph) as the agent sees it: the words, and the buttons or list rows to choose from
function asReply(s: Sent): Reply {
  const p = s.payload;
  const a = p?.interactive?.action;
  const buttons = [...(a?.buttons || []).map((b) => b.reply), ...(a?.sections || []).flatMap((x) => x.rows || [])]
    .filter((b): b is Choice => !!b?.id).map((b) => ({ id: String(b.id), title: String(b.title || '') }));
  const text = p?.type === 'text' ? p.text?.body : p?.type === 'interactive' ? p.interactive?.body?.text
             : p?.type === 'image' ? p.image?.caption : s.body;
  return { text: String(text || s.body || '').replace(/^📞 _On your call: "[^"]*"_\n\n/, ''), ...(buttons.length ? { buttons } : {}) };
}

// The bot's messages to this person since `since` (ISO time), oldest first
export async function sentSince(wa: string, since: string): Promise<{ replies: Reply[]; last: string }> {
  const list = await rows<Sent>(`
    SELECT m.created_at::text AS at, m.payload, m.body FROM public.tori_messages m
     WHERE m.user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || $1)
       AND m.direction = 'out' AND m.created_at > $2::timestamptz
     ORDER BY m.created_at, m.id`, [wa, since]);
  return { replies: list.map(asReply), last: list.length ? String(list.at(-1)!.at) : since };
}

// One turn of the conversation: hand it to the bot, then wait for its replies (they arrive within a few seconds;
// the bot may send several messages, so wait until it has been quiet for a moment). Gives up after `maxMs`; the
// rest can be fetched with sentSince (MCP check_tori_replies).
export async function talk(c: Caller, m: { text?: string; button?: { id: string; title: string } }, maxMs = 15000)
  : Promise<{ ok: boolean; replies: Reply[]; since: string; waiting: boolean }> {
  const [{ now }] = await rows<{ now: string }>('SELECT now()::text AS now');
  await rpc('SELECT public.tori_agent_said($1, $2)', [c.wa_id, m.button ? m.button.title : m.text || '']);
  if (!(await relay(c, m))) return { ok: false, replies: [], since: now, waiting: false };
  const start = Date.now();
  let got: Reply[] = [];
  let lastAt = now;
  let quietSince = 0;
  while (Date.now() - start < maxMs) {
    await new Promise((r) => setTimeout(r, 700));
    const { replies, last } = await sentSince(c.wa_id, now);
    if (replies.length !== got.length) { got = replies; lastAt = last; quietSince = Date.now(); }
    else if (got.length && Date.now() - quietSince > 2500) break;
  }
  // since = the newest reply handed back (database time), where check_tori_replies picks up
  return { ok: true, replies: got, since: lastAt, waiting: !got.length };
}

type Snapshot = {
  name: string | null; name_confirmed: boolean; since: string | null; profile: { status?: string; missing?: string[] } | null;
  p: { requests: Record<string, unknown>[]; joins: Record<string, unknown>[] };
  t: { request: Record<string, unknown> | null; awaiting_answer: boolean }; balance: string | null;
};

// What Tori knows about this person: profile, live requests, wallet. Given to the agent when a call starts
// (/api/agent/context → voice-bridge → Vapi variable tori_caller) and by get_my_status.
export async function snapshot(wa: string) {
  const [s] = await rows<Snapshot>(`
    SELECT u.name, coalesce(u.name_source = 'user', false) AS name_confirmed, to_char(u.created_at, 'DD Mon YYYY') AS since,
           public.tori_profile_context($1) AS profile, public.tori_partner_status($1) AS p, public.travel_context($1) AS t,
           public.wallet_balance(u.id) AS balance
      FROM (SELECT 1) one LEFT JOIN public.tori_users u ON u.phone = '+' || $1`, [wa]);
  const known = !!s.since;
  const rupees = '₹' + (Number(s.balance || 0) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 });
  return {
    known, name: s.name, name_confirmed: s.name_confirmed, on_tori_since: s.since,
    profile: s.profile?.status === 'complete' ? 'complete' : `incomplete (Tori still needs: ${(s.profile?.missing || []).join(', ') || 'name'})`,
    partner_requests: s.p.requests, games_asked_to_join: s.p.joins,
    cab_buddy_request: s.t.request, cab_match_waiting_for_their_answer: s.t.awaiting_answer,
    wallet_balance: rupees,
  };
}

// the same, as a few lines for the agent's prompt
export function describe(x: Awaited<ReturnType<typeof snapshot>>, wa: string) {
  if (!x.known || x.profile !== 'complete') {
    return `No Tori account yet${x.known && x.name ? ` (WhatsApp name: ${x.name})` : ''}: they haven't finished setting up their profile. `
      + 'Finding partners, cab buddies and joining games need an account, and it is created in their WhatsApp chat with Tori, '
      + 'not on this call. The wallet link, invite code and open games work without one.'
      + (x.cab_buddy_request ? ` Cab-buddy request: ${JSON.stringify(x.cab_buddy_request)}.` : '')
      + (x.partner_requests.length ? ` Partner requests: ${JSON.stringify(x.partner_requests)}.` : '');
  }
  const list = (v: Record<string, unknown>[]) => (v.length ? JSON.stringify(v) : 'none');
  return [
    `Name: ${x.name || 'unknown'}${x.name_confirmed ? ' (confirmed)' : ' (from their WhatsApp profile, not confirmed yet: Tori will ask)'}`,
    `On Tori since ${x.on_tori_since}. Profile: ${x.profile}.`,
    `Partner requests: ${list(x.partner_requests)}. Games they asked to join: ${list(x.games_asked_to_join)}.`,
    `Cab-buddy request: ${x.cab_buddy_request ? JSON.stringify(x.cab_buddy_request) : 'none'}`
      + (x.cab_match_waiting_for_their_answer ? ' (a cab match is waiting for their yes or no)' : '') + '.',
    `Tori Wallet: ${x.wallet_balance}.`,
  ].join('\n');
}

// Where their account setup is (profile questions or "please confirm your name", both in the WhatsApp chat):
// null when nothing is being set up, else which question is waiting
export async function setupStep(wa: string): Promise<string | null> {
  const [r] = await rows<{ step: string | null }>(`
    SELECT CASE WHEN s.state = 'awaiting_profile' OR (s.name_step IS NOT NULL AND s.name_asked_at > now() - interval '1 day')
                THEN concat_ws(':', s.state, public.tori_profile_context($1) ->> 'next', s.name_step) END AS step
      FROM public.tori_conversation_state s JOIN public.tori_users u ON u.id = s.user_id
     WHERE u.phone = '+' || $1`, [wa]);
  return r?.step ?? null;
}

// The MCP server's own key: Vapi sends it as x-tori-mcp-key (the MCP tool's server.headers, scripts/vapi-mcp.sh)
export function isAgent(req: Request) {
  const key = process.env.TORI_MCP_KEY || '';
  const got = Buffer.from(req.headers.get('x-tori-mcp-key') || '');
  return !!key && got.length === Buffer.byteLength(key) && crypto.timingSafeEqual(got, Buffer.from(key));
}
