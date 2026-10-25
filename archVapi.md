# Tori voice agent (Vapi) · Architecture

How the Harsh AI voice agent (Vapi) works with the Tori WhatsApp bot: what was built, how a call flows, and
where each part lives. The audio side (voice-bridge, Meta's Calling API, workflow 13) is described in
[docs/VOICE.md](docs/VOICE.md). This document covers how the agent *does things* in Tori and stays in step with
the WhatsApp chat.

## Contents

1. [The idea in one paragraph](#1-the-idea-in-one-paragraph)
2. [The big picture](#2-the-big-picture)
3. [A call, step by step](#3-a-call-step-by-step)
4. [Who is calling](#4-who-is-calling)
5. [The Tori MCP server](#5-the-tori-mcp-server)
6. [One conversation: how the agent hears the bot](#6-one-conversation-how-the-agent-hears-the-bot)
7. [New callers: the account is made in the chat](#7-new-callers-the-account-is-made-in-the-chat)
8. [The agent's prompt](#8-the-agents-prompt)
9. [Data](#9-data)
10. [Configuration](#10-configuration)
11. [Security](#11-security)
12. [Tests](#12-tests)
13. [Operations and troubleshooting](#13-operations-and-troubleshooting)
14. [Known limits and next steps](#14-known-limits-and-next-steps)
15. [Files](#15-files)

## 1. The idea in one paragraph

There is **one brain: the WhatsApp bot** (n8n workflow 06 with its Groq LLM). It already knows how to onboard
people, check names, find partners and cab buddies, run joins and the wallet. The voice agent does not
re-implement any of that. On a call, it is the bot's **voice**:
- what the caller says is handed to the bot as if they had typed it in WhatsApp;
- the bot's reply comes back to the agent, which says it;
- the same reply lands in the caller's WhatsApp chat.

So a request started on a call can be finished in the chat, or the other way round. Both read and write the same
Postgres state.

## 2. The big picture

```text
                       ┌──────────────── WhatsApp call (Meta Calling API, WebRTC) ────────────────┐
 Caller's phone ◄──────┤                                                                          │
      ▲                └──► voice-bridge ──(PCM over WSS)──► Vapi assistant "Harsh AI" (gpt-5-mini) │
      │                        │  POST /call with                    │                             │
      │                        │  variableValues.tori_caller ◄───────┼── web /api/agent/context    │
      │                        │                                     │                             │
      │                        │                    MCP tool calls   ▼  (x-tori-mcp-key, X-Call-Id) │
      │                        │                          web /api/mcp  (Tori MCP server)          │
      │                        │                     reads ──► Postgres                            │
      │                        │                     message_tori ──► signed "WhatsApp message"    │
      │                        │                                       from the caller ──► n8n 06  │
      │                        │                                                           (bot)   │
      │   WhatsApp chat        │                                                             │     │
      └───────────────◄────────┼── Meta Graph API ◄── web /api/graph (logs every send) ◄──────┘     │
                               │                        └──► tori_messages (direction 'out')        │
                               │                             ▲                                      │
                               │                             └── message_tori reads the bot's reply │
```

| Piece | Where | Role |
|---|---|---|
| Vapi assistant | Vapi dashboard (`VAPI_ASSISTANT_ID`) | The voice: speech in and out, the LLM that talks to the caller |
| voice-bridge | `voice-bridge/` | Joins a WhatsApp call to Vapi; tells Vapi who is calling |
| Tori MCP server | `web/src/app/api/mcp/route.ts` | The agent's tools: talk to the bot, search games, read the caller's status |
| Caller context | `web/src/app/api/agent/context/route.ts` | "Who is calling", for the prompt, when a call starts |
| Graph pass-through | `web/src/app/api/graph/[...path]/route.ts` | Every bot send goes through it on its way to Meta, so it can be logged |
| WhatsApp bot | n8n workflow 06 (`plan/build_partner_workflow.py`) | The brain, unchanged in principle |
| Setup script | `scripts/vapi-mcp.sh` | Registers the MCP tool in Vapi and keeps the prompt's Tori section |

## 3. A call, step by step

1. **The call comes in.** Meta sends the `calls` webhook to n8n 06, which hands it to workflow 13 and then to
   voice-bridge (see docs/VOICE.md).
2. **voice-bridge looks the caller up.** Before creating the Vapi call it posts `{ wa_id }` to
   `web /api/agent/context` (2.5 s timeout). It passes the answer to Vapi as the variable `tori_caller`, next
   to `callerName`. If Tori can't be reached, the call still starts, with a fallback text that says "use
   get_my_status".
3. **Vapi starts the assistant.** The prompt's "Tori integration" section contains `{{tori_caller}}`, so the
   agent knows from the first second, for example: *"Name: Harsh (confirmed). Profile: complete. Partner
   requests: tennis, HSL, 26 Oct 9 PM. Cab-buddy request: none. Wallet: ₹0."*. For a new caller it says *"No
   Tori account yet…"*.
4. **Vapi lists the MCP tools.** At call start Vapi fetches the tool list from `/api/mcp`.
5. **The caller asks for something** ("tennis tomorrow 6 pm in HSR"). The agent calls
   `message_tori { text }`. The MCP server:
   - finds the caller from `X-Call-Id`;
   - records what was said (`agent_echo`);
   - posts it to n8n's WhatsApp Trigger as a WhatsApp message from the caller, signed with the Meta app secret;
   - waits for the bot's replies (section 6) and returns them, with their buttons.
6. **The agent says the gist and asks what the bot asked** ("What time works?"). The answer goes back with
   `message_tori`; a choice goes back as `button_id`. A spoken "interested" or "yes, that's me" that matches a
   button's title is sent as that button.
7. **Everything is in the chat too.** Every bot message the agent heard is also delivered to WhatsApp. The first
   message after each thing said on the call starts with it: 📞 *On your call: "6 pm"*.
8. **Later news** (a match found during the call, a slow reply) is fetched with `check_tori_replies`.
   After the call it simply arrives in the chat, as it always did.

## 4. Who is calling

- **WhatsApp calls:** voice-bridge logs each call in `voice_calls` with Meta's call ID, Vapi's call ID and the
  caller's number (`caller_wa_id`, vouched for by WhatsApp). Vapi sends `X-Call-Id` with every MCP request, and
  `lib/agent.ts callerFor()` maps it to the caller. It only does so while the call is live (or within 2 minutes
  of its end) and for at most 3 hours.
- **Website calls (`/voice`):** anonymous. The web page passes
  `variableValues.tori_caller = "A visitor on the Tori website, not identified…"`. `search_open_games` works;
  every personal tool returns `not_identified`, and the agent asks them to call or message Tori on WhatsApp.
- **What the agent is told** (`snapshot()` + `describe()` in `lib/agent.ts`): name and whether it is confirmed,
  profile status and missing steps, live partner requests and joins (`tori_partner_status`), cab-buddy request
  (`travel_context`), wallet balance.

## 5. The Tori MCP server

`POST /api/mcp`. MCP over Streamable HTTP, stateless: plain JSON answers, no session, no SSE stream (`GET` →
405). Vapi opens a new connection for each tool call anyway. Implemented by hand, with no SDK: `initialize`
(echoes the client's protocol version), `ping`, `tools/list`, `tools/call`; notifications get 202. Every request
needs `x-tori-mcp-key: TORI_MCP_KEY`.

| Tool | Input | What it does |
|---|---|---|
| `message_tori` | `{ text }` or `{ button_id }` | One turn with the bot (section 6). Returns `{ status: 'ok', replies: [{ text, buttons? }] }`, `working` (no reply within 15 s), `needs_account` (section 7), `unknown_button`, `limit`, `not_identified` |
| `check_tori_replies` | none | Bot messages since the last reply handed back |
| `search_open_games` | `activity`, `city`, `area`, `when` | Open games on the board (`lib/board.ts getRequests`): host first name, area, time, spots, join code. Works for anyone |
| `get_my_status` | none | The caller's snapshot (section 4) |

Limits: 30 turns per call; a `button_id` must be one of the buttons in the bot's last reply. There are no
payment tools, on purpose: money never moves by voice. Each tool call is logged:
`docker compose logs web | grep "mcp tool"` prints the tool, the last 4 digits of the caller, and the status.

## 6. One conversation: how the agent hears the bot

The bot sends its replies to Meta from about 67 HTTP nodes, in workflows 06 and 11. They all use
`$env.BOT_WHATSAPP_GRAPH_URL`. In docker-compose that now points at the web app:

```text
n8n  BOT_WHATSAPP_GRAPH_URL      = http://web:3000/api/graph
     BOT_WHATSAPP_GRAPH_UPSTREAM = .env's BOT_WHATSAPP_GRAPH_URL (default https://graph.facebook.com/v19.0)
web  WHATSAPP_GRAPH_UPSTREAM     = the same
```

`/api/graph/<path>` passes every request on unchanged: method, path, query, `Authorization`, body, and the
response back. For sent messages (`POST <phone id>/messages`) it also:

1. **adds the echo.** If the caller said something on a call in the last minute (`tori_take_echo`), the first
   message to them starts with 📞 *On your call: "…"*. This works for text messages, interactive bodies and
   image captions.
2. **logs the message** after Meta accepts it: `tori_log_bot_message(to, message id, type, words, payload)`. The
   payload is the message without `to`, buttons and list rows included. Logging is fire-and-forget: it never
   delays or fails a send.

`message_tori` (`lib/agent.ts talk()`) then:
- notes the database time;
- relays the message;
- polls `tori_messages` (direction `out`, this caller, newer than that time) every 700 ms;
- stops when at least one reply has arrived and nothing new came for 2.5 s, or after 15 s.

The bot often sends two messages ("You're all set ✅" and then "Done ✅ I've asked the host…"), and the quiet
window catches both.

**Network blips:** if the connection to Meta fails before the request goes out (connection refused or reset,
DNS, unreachable), the pass-through retries twice, after 1 s and 2 s. Meta never got it, so nothing is sent
twice. Timeouts are not retried. Other failures return 502, and the bot carries on as it did before.

**Chat side:** "Am I looking for a cab?" in the chat is a status question (`check_status`). The status reply now
includes the cab-buddy request (`travel_context`), so a trip asked for on a call shows up in the chat.

## 7. New callers: the account is made in the chat

The profile is 7 questions: name, age, gender, interests, link, photo, about. That is too much for a call, so
account setup happens in the WhatsApp chat:

- When a request needs an account, the bot parks the request (`pending_profile`) and sends its first setup
  question. The question goes to the chat, with the echo, because the bot sends it like any other message.
- `message_tori` compares `setupStep()` before and after the turn. That function returns the onboarding state,
  the next profile step and any pending name check. If the turn started setup, or it answered one of the setup
  questions, the tool returns `needs_account` instead of the question. The questions are recognised by their
  `pf_` / `nm_` buttons or their wording. The agent tells the caller, politely, to finish in WhatsApp; the
  saved request carries on by itself afterwards.
- A wallet link, invite code or open-game search during setup still comes back normally.
- The "Please confirm your name" step (db 017) counts as setup too.

## 8. The agent's prompt

The prompt is yours and is edited in the Vapi dashboard. `scripts/vapi-mcp.sh` owns **one marked section at the
end** of the system message. It is wrapped in `<!-- TORI INTEGRATION … -->` / `<!-- /TORI INTEGRATION -->`, and
running the script again replaces only that section:

- **Who is calling:** `{{tori_caller}}`.
- **How to speak:**
  - answer first, in one sentence of about 15 words;
  - don't repeat their request back, and never read out codes;
  - at most one question per turn, and no lists of options;
  - explanations in two sentences;
  - mention WhatsApp once per call.
- **How to work:**
  - Tori is the source of truth;
  - call `message_tori` at once with the caller's words, and don't collect or confirm details first;
  - relay Tori's questions and buttons;
  - use `get_my_status` for status and name questions;
  - no account means it is set up in WhatsApp, and profile questions are never asked on the call.

The section says it is "the final word" where earlier parts of the prompt disagree (for example, their own
slot-filling and confirmation rules). The script also creates or updates the Vapi MCP tool `toriTools`:
`server.url = BOARD_PUBLIC_URL/api/mcp`, header `x-tori-mcp-key`, protocol `shttp`. It attaches the tool to the
assistant (`model.toolIds`). It changes nothing else, and it is idempotent ("already up to date").

## 9. Data

| Table / column | Migration | Holds |
|---|---|---|
| `voice_calls`, `voice_call_events` | 015 | Every call: Meta and Vapi IDs, caller, state; used to identify the caller |
| `tori_messages.payload` (+ `direction = 'out'` rows) | 018 | Every bot message as sent, with buttons: what `message_tori` reads |
| `agent_echo (wa_id, said, at)` | 018 | What the caller just said, until the bot's next message to them (1 minute) |
| `tori_conversation_state.name_step / name_resume` | 017 | The pending "confirm your name" question |

Functions (all revoked from Supabase's `anon` / `authenticated`): `tori_log_bot_message`, `tori_agent_said`,
`tori_take_echo` (018); `tori_name_gate`, `tori_name_answer`, `tori_clean_name` (017). The MCP server also reads
`tori_partner_status`, `travel_context`, `tori_profile_context`, `wallet_balance` and `v_partner_board`.

## 10. Configuration

`.env`:

| Variable | Used by | Meaning |
|---|---|---|
| `TORI_MCP_KEY` | web, voice-bridge, Vapi tool header | Shared secret for `/api/mcp` and `/api/agent/context` (`openssl rand -hex 32`) |
| `VAPI_PRIVATE_API_KEY`, `VAPI_ASSISTANT_ID` | voice-bridge, `vapi-mcp.sh` | Vapi account and assistant |
| `BOARD_PUBLIC_URL` | `vapi-mcp.sh` | Public address of the web app (board tunnel): where Vapi reaches `/api/mcp` |
| `BOT_META_APP_SECRET` | web | Signs messages handed to the bot, like Meta signs webhooks |
| `BOT_WHATSAPP_TOKEN` | n8n, voice-bridge | Meta token: sends, calls (n8n passes it through `/api/graph`) |
| `BOT_WHATSAPP_GRAPH_URL` | web (upstream) | Where `/api/graph` forwards; empty = Meta |

docker-compose sets the rest: `TORI_BOT_INBOUND_URL` (n8n's WhatsApp Trigger, `/webhook/<id>/webhook`),
`WHATSAPP_GRAPH_UPSTREAM`, n8n's `BOT_WHATSAPP_GRAPH_URL = http://web:3000/api/graph`, and voice-bridge's
`TORI_CONTEXT_URL` (default `http://web:3000/api/agent/context`). n8n starts after web.

## 11. Security

- **MCP server and caller context:** require `TORI_MCP_KEY` (constant-time compare). Without a key, or with a
  wrong one, the answer is 401.
- **Acting for a caller:** only for a live WhatsApp call logged by voice-bridge. The phone number comes from
  WhatsApp, not from anything the caller says.
- **Handing messages to the bot:** they are signed with the Meta app secret, and the WhatsApp Trigger checks the
  signature as it does for Meta.
- **`/api/graph`:** refuses anything that came through the public tunnel (Cloudflare headers → 404) and anything
  without an `Authorization` header (401). It is for n8n inside the Docker network only.
- **Payments:** no payment tools, at most 30 turns per call, and `button_id` limited to the buttons Tori offered.
- **Privacy:** the MCP log line shows only the last 4 digits. `search_open_games` returns first names, never
  numbers.

## 12. Tests

| Test | Run | Covers |
|---|---|---|
| `scripts/mcp_e2e.py` | `E2E_ONLY=mcp scripts/travel-e2e.sh` (about 4 min) | See below |
| `voice-bridge/test/control.test.js` | `cd voice-bridge && node --test test/` | Vapi call creation with `tori_caller`; the call still starts when Tori is down |
| Full suite | `scripts/travel-e2e.sh` | Every bot conversation now goes through `/api/graph` too |

`scripts/mcp_e2e.py` has about 45 checks. They cover:
- the protocol, the key, and that the pass-through refuses public requests;
- reply plus echo in the chat, and the payload logged;
- a new caller sent to the chat, setup finished there, and the join from the call going on;
- a missing time asked on the call;
- a match card on the call, with "interested" said out loud;
- `check_tori_replies`;
- a cab request on the call, then "Am I looking for any cab?" in the chat;
- "HSL Bangalore" as an area, and a match;
- ended calls.

The tests run in a throwaway stack: real Groq, and mock WhatsApp and geocoder.

## 13. Operations and troubleshooting

| Symptom | Look at | Usual cause |
|---|---|---|
| Phone keeps ringing, nobody answers | `voice_calls.end_reason`, `docker compose logs voice-bridge` | Expired `BOT_WHATSAPP_TOKEN` (`pre_accept failed (401)`), or the bot tunnel is down |
| The agent talks but does nothing | `docker compose logs web \| grep "mcp tool"` (empty = no tool calls) | Board tunnel changed and Vapi has the old URL: run `scripts/vapi-mcp.sh` |
| The agent doesn't know the caller | voice-bridge log, `/api/agent/context` | `TORI_MCP_KEY` missing in voice-bridge, or web down |
| Bot replies "having a little trouble" | Groq response headers | Groq free tier: 8k tokens per minute, shared by tests, chat and calls |
| A chat message never arrived | `docker compose logs web \| grep graph`, n8n execution | Meta unreachable (`fetch failed`); the pass-through retries connection errors |
| Call drops after about 40 s | voice-bridge `media_failed` | The network on the machine running voice-bridge (Wi-Fi, sleep) |

Tunnels: `scripts/bot-tunnel.sh` (Meta webhook) and `scripts/board-tunnel.sh` (board, and Vapi's tool URL; it
runs `vapi-mcp.sh` by itself).

## 14. Known limits and next steps

- **Groq's free tier** (8k tokens per minute, about 2k per bot turn) allows about 4 bot turns a minute across all
  users. The bot retries 3 times, 4 s apart, but a paid Groq key (or a shorter prompt) is needed for real use.
- **Short-lived Meta tokens** expire after hours. Use a System User token that never expires.
- **Quick tunnels and the laptop:** addresses change on restart, and calls drop when the network does. Run the
  stack on a server with a fixed domain; then `vapi-mcp.sh` only needs to run once.
- **The web app is now on the bot's send path.** If web is down, the bot can't send. It is a thin pass-through
  and restarts by itself, but for production consider a health alert.
- **The old "Connect" placeholder** ("Got it! I'm already working on finding the perfect connection") is still
  sent for "like-minded people" messages, and it does nothing. Build the feature or remove the reply.
- **Website callers are anonymous.** A login (for example the wallet's WhatsApp link) could identify them too.

## 15. Files

| File | What |
|---|---|
| `web/src/app/api/mcp/route.ts` | Tori MCP server: protocol, the 4 tools, `needs_account`, button matching |
| `web/src/lib/agent.ts` | `callerFor`, `relay`, `talk`, `sentSince`, `snapshot`, `describe`, `setupStep`, `isAgent` |
| `web/src/app/api/agent/context/route.ts` | Who is calling, for voice-bridge |
| `web/src/app/api/graph/[...path]/route.ts` | Graph API pass-through: echo, outbox log, network retry |
| `web/src/components/voice-agent.tsx` | Website calls pass `tori_caller` (anonymous visitor) |
| `voice-bridge/src/vapi.js`, `config.js` | Caller context into `variableValues.tori_caller` |
| `db/migrations/018_bot_outbox_log*.sql` | Outbox payload, `agent_echo` and their functions |
| `db/migrations/017_name_confirm*.sql` | "Please confirm your name" |
| `plan/build_partner_workflow.py` | Bot changes: status includes cab, LLM retries, short answers to "Which area?", name gate (section 18) |
| `scripts/vapi-mcp.sh` | Vapi MCP tool and the prompt's Tori section |
| `scripts/mcp_e2e.py` | End-to-end test |
| `docker-compose.yml` | `BOT_WHATSAPP_GRAPH_URL` → web, `TORI_MCP_KEY`, `TORI_BOT_INBOUND_URL`, upstream URLs |
