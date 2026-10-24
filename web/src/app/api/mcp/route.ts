import { callerFor, isAgent, sentSince, setupStep, snapshot, talk, type Caller } from '@/lib/agent';
import { botNumber, getRequests, parseFilters, WHEN, type When } from '@/lib/board';

// POST /api/mcp — the Tori MCP server for the Harsh AI voice agent (Vapi "MCP" tool, docs/VOICE.md).
// Streamable HTTP, stateless: every request is answered with JSON, no session and no SSE stream (Vapi opens a
// new connection for each tool call anyway). Requests need x-tori-mcp-key.
//
// One conversation, one brain: the WhatsApp bot decides what to ask and do, on the call as in the chat.
// message_tori hands the bot what the caller said (or the button they chose) and returns the bot's replies for the
// agent to say; the same messages land in their WhatsApp chat, so either can carry on where the other stopped.
// Two quick reads (open games, the caller's status) are answered straight from Postgres. Payments stay off.

type Args = Record<string, unknown>;
type Result = Record<string, unknown>;
type Tool = { name: string; description: string; inputSchema: object; run: (a: Args, c: Caller | null, callId: string) => Promise<Result> };

const str = (v: unknown, max = 60) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, max);
const HOW = "Say only the gist of Tori's reply, in one short sentence (no links, emojis, codes or repeated details). "
  + 'If Tori asks something, ask the caller just that and send their answer with message_tori; if the reply has '
  + 'buttons, name the choices briefly and send the chosen one as button_id.';

// a new caller: the account is made in the WhatsApp chat (the profile questions don't belong on a call)
const ACCOUNT = { status: 'needs_account',
  note: "They don't have a Tori account yet, and it is created in their WhatsApp chat. Tell them politely: Tori has sent them "
    + 'a message on WhatsApp; answering a few quick questions there sets up their account, and what they asked for is '
    + 'saved and carries on by itself once that is done. After that they can call again and do everything by voice.' };

// the bot's own setup questions (Build profile reply and the name check, workflow 06)
const SETUP_QUESTION = /How old are you\?|What do you like to play or do\?|May I know your name|Please type the name|confirm your name|Send a profile photo|Tell me a bit about yourself/;

function notIdentified(): Result {
  const bot = botNumber();
  return { status: 'not_identified',
    note: 'This needs to know who the caller is, which works when they call Tori on WhatsApp. On this call, ask them '
      + `to message or call Tori on WhatsApp${bot ? ` (+${bot})` : ''}.` };
}

// per call: how many turns (so a confused conversation can't flood a chat), the last reply handed back, and the
// buttons Tori offered last (a button_id must be one of them)
const MAX_TURNS = 30;
const calls = new Map<string, { turns: number; since: string; buttons: { id: string; title: string }[] }>();
function callState(id: string) {
  let s = calls.get(id);
  if (!s) {
    s = { turns: 0, since: new Date().toISOString(), buttons: [] };
    calls.set(id, s);
    if (calls.size > 1000) calls.delete(calls.keys().next().value!);
  }
  return s;
}

const TOOLS: Tool[] = [
  {
    name: 'message_tori',
    description: 'Talk to Tori (the WhatsApp bot) for the caller. It does everything Tori does in the chat: find an '
      + 'activity or sports partner, find a cab buddy, join a game by code, check matches, cancel a request, send a '
      + 'wallet top-up link, give an invite code, update their profile. Send what the caller wants in their own words, '
      + 'as they would type it ("tennis tomorrow 6 pm in HSR Layout, Bangalore, 3 players"), as soon as they say it: '
      + "don't ask for details first, Tori asks for whatever is missing. Also use it to send the caller's answer to "
      + "Tori's last question, or the button they chose (button_id). Returns Tori's replies. " + HOW,
    inputSchema: { type: 'object', additionalProperties: false, properties: {
      text: { type: 'string', description: "what the caller wants or answered, in their words (English, Hindi or Hinglish)" },
      button_id: { type: 'string', description: "the id of a button from Tori's last reply, when the caller chose one" },
    } },
    async run(a, c, id) {
      if (!c) return notIdentified();
      const s = callState(id);
      if (++s.turns > MAX_TURNS) return { status: 'limit', note: 'Too many turns on this call. Ask them to continue in the WhatsApp chat.' };
      const button = a.button_id ? s.buttons.find((b) => b.id === str(a.button_id, 120)) : undefined;
      if (a.button_id && !button) {
        return { status: 'unknown_button', note: "That button isn't in Tori's last reply.", buttons: s.buttons };
      }
      let text = str(a.text, 500);
      // the caller's answer is one of Tori's buttons ("Yes, that's me"): tap it, so Tori takes it as the answer
      const said = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
      const tapped = button || (text ? s.buttons.find((b) => said(b.title) === said(text)) : undefined);
      if (!tapped && !text) return { status: 'empty', note: 'Send the caller\'s words as text, or a button_id.' };
      if (tapped) text = '';
      const before = await setupStep(c.wa_id);
      const r = await talk(c, tapped ? { button: tapped } : { text });
      if (!r.ok) return { status: 'failed', note: "Couldn't reach Tori just now. Say so, and suggest trying again in a minute." };
      s.since = r.since;
      s.buttons = r.replies.flatMap((x) => x.buttons || []);
      // the request needs an account first (Tori saved it and started the setup in their chat), or this answered one
      // of the setup questions: the rest happens in the chat. A wallet link or invite during setup comes back as usual.
      const after = await setupStep(c.wa_id);
      const asksSetup = r.replies.some((x) => (x.buttons || []).some((b) => /^(pf|nm)_/.test(b.id)) || SETUP_QUESTION.test(x.text));
      if (after && (after !== before || asksSetup)) return ACCOUNT;
      return r.waiting
        ? { status: 'working', note: 'Tori is still working on it. Tell the caller, and use check_tori_replies in a few seconds.' }
        : { status: 'ok', replies: r.replies, note: HOW };
    },
  },
  {
    name: 'check_tori_replies',
    description: "Tori's messages to the caller that arrived since its last reply (for example after \"still working\", "
      + 'or a match found while you were talking). ' + HOW,
    inputSchema: { type: 'object', additionalProperties: false, properties: {} },
    async run(_a, c, id) {
      if (!c) return notIdentified();
      const s = callState(id);
      const { replies, last } = await sentSince(c.wa_id, s.since);
      s.since = last;
      if (replies.length) s.buttons = replies.flatMap((x) => x.buttons || []);
      return replies.length ? { status: 'ok', replies, note: HOW } : { status: 'nothing_new' };
    },
  },
  {
    name: 'search_open_games',
    description: 'Open games and partner requests on the Tori board that people can join, soonest first (first names only, '
      + 'never numbers). Works for everyone, also on the website. To join one, send "JOIN <join_code>" with message_tori.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {
      activity: { type: 'string', description: 'lower-case English: badminton, football, cricket, tennis, table_tennis, pickleball, gym, running …' },
      city: { type: 'string', description: 'lower-case: bangalore, delhi, mumbai, prayagraj …' },
      area: { type: 'string', description: 'neighbourhood, e.g. HSR Layout' },
      when: { type: 'string', enum: ['upcoming', 'today', 'tomorrow', 'weekend', 'week'] },
    } },
    async run(a) {
      const when = (WHEN as readonly string[]).includes(str(a.when)) ? (str(a.when) as When) : 'upcoming';
      const f = { ...parseFilters({}), activity: str(a.activity, 40).toLowerCase().replace(/\s+/g, '_'),
                  city: str(a.city, 40).toLowerCase(), q: str(a.area), when, limit: 6 };
      const { items, total } = await getRequests(f);
      return { total, games: items.map((r) => ({
        activity: r.activity.replace(/_/g, ' '), host: r.first_name, area: r.area, city: r.city, date: r.play_date,
        time: r.time_label, level: r.skill_level, spots: r.players_needed, joined: r.joined_count,
        status: r.board_status === 'matched' ? 'full' : r.board_status, join_code: r.join_code })) };
    },
  },
  {
    name: 'get_my_status',
    description: "What Tori knows about the caller right now: their name and profile, live partner requests (matches "
      + 'waiting, who joined), games they asked to join, their cab-buddy request and Tori Wallet balance. Use it for '
      + '"what\'s my status", "any match?", "am I looking for a cab?", "what\'s my name?", "my balance".',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} },
    async run(_a, c) {
      return c ? snapshot(c.wa_id) : notIdentified();
    },
  },
];

// MCP protocol versions are dates; the tools-only subset used here is the same in all of them
const LATEST = '2025-06-18';
type Msg = { jsonrpc?: string; id?: string | number | null; method?: string; params?: Args };

async function handle(m: Msg, callId: string): Promise<object | null> {
  if (m?.id === undefined || m.id === null) return null;                    // a notification: nothing to answer
  const ok = (result: object) => ({ jsonrpc: '2.0', id: m.id, result });
  const fail = (code: number, message: string) => ({ jsonrpc: '2.0', id: m.id, error: { code, message } });
  switch (m.method) {
    case 'initialize': {
      const v = String(m.params?.protocolVersion || '');
      return ok({ protocolVersion: /^\d{4}-\d{2}-\d{2}$/.test(v) && v >= '2024-11-05' ? v : LATEST,
                  capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'tori', version: '2.0.0' },
                  instructions: 'Tori, the WhatsApp bot: talk to it for the caller with message_tori. One conversation '
                    + 'with their WhatsApp chat.' });
    }
    case 'ping':
      return ok({});
    case 'tools/list':
      return ok({ tools: TOOLS.map(({ run: _run, ...t }) => t) });
    case 'tools/call': {
      const tool = TOOLS.find((t) => t.name === m.params?.name);
      if (!tool) return fail(-32602, `unknown tool ${String(m.params?.name)}`);
      try {
        const caller = callId ? await callerFor(callId) : null;
        const result = await tool.run((m.params?.arguments as Args) || {}, caller, callId);
        console.log('mcp tool', tool.name, caller ? `…${caller.wa_id.slice(-4)}` : 'anonymous', result.status || 'ok');
        return ok({ content: [{ type: 'text', text: JSON.stringify(result) }], isError: false });
      } catch (e) {
        console.error('mcp tool', tool.name, (e as Error).message);
        return ok({ content: [{ type: 'text', text: JSON.stringify({ status: 'error', note: 'Tori had a problem with that. Say so and suggest trying again.' }) }], isError: true });
      }
    }
    default:
      return fail(-32601, `method not found: ${String(m.method)}`);
  }
}

export async function POST(req: Request) {
  if (!isAgent(req)) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'unauthorized' } }, { status: 401 });
  const body = await req.json().catch(() => undefined);
  if (body === undefined) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }, { status: 400 });
  const callId = req.headers.get('x-call-id') || '';
  const batch = Array.isArray(body);
  const out = (await Promise.all((batch ? body : [body]).map((m: Msg) => handle(m, callId)))).filter(Boolean);
  if (!out.length) return new Response(null, { status: 202 });
  return Response.json(batch ? out : out[0]);
}

// no server-to-client stream (stateless server)
export function GET() {
  return new Response(null, { status: 405, headers: { Allow: 'POST' } });
}
