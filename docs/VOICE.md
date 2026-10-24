# Harsh AI voice assistant: web page + WhatsApp calls

One Vapi assistant (`afd96ebf-40a7-40d2-bc0b-b6b94367e588`, configured in the Vapi dashboard: its system prompt
is not touched here) reached two ways:

| Transport | Path | Code |
|---|---|---|
| Browser | `/voice` on the board app → `@vapi-ai/web` (WebRTC via Daily) → Vapi | [web/src/components/voice-agent.tsx](../web/src/components/voice-agent.tsx) |
| WhatsApp call | Meta Calling API (WebRTC) → **voice-bridge** → Vapi WebSocket transport (raw PCM) | [voice-bridge/](../voice-bridge/) |

`@vapi-ai/web` only runs in a browser and cannot answer a WhatsApp call, so the two are separate transports
to the same assistant.

```text
WhatsApp caller ──(Opus/SRTP, ICE, DTLS)──► voice-bridge ──(pcm_s16le 16 kHz over WSS)──► Vapi ─► Harsh AI
      ▲                                       │    ▲                                        │
      └────────────── assistant audio ────────┘    └──────── assistant audio (PCM) ─────────┘

Meta `calls` webhook ─► n8n 06 (WhatsApp Trigger, checks X-Hub-Signature-256) ─► n8n 13 ─► bridge POST /calls/event
bridge ─► n8n 13 /webhook/voice/events (lifecycle) ─► public.voice_calls / voice_call_events
Vapi Server URL ─► n8n 13 /webhook/vapi/events (tool calls, end-of-call report)
```

n8n is the control plane only. No audio frame passes through an n8n execution.

## What each piece does

**voice-bridge** (Node 22, `@roamhq/wrtc` = libwebrtc bindings, `ws`): one `CallSession` per WhatsApp call
([session.js](../voice-bridge/src/session.js)). Each session owns its own peer connection, audio source and
sink, resampler, playout queue, Vapi call and socket, and timers. Nothing is shared between calls.

1. **Connect webhook** (SDP offer). The bridge answers it with non-trickle ICE: it waits for ICE gathering,
   because Meta takes a single SDP.
2. **In parallel**, it sends `pre_accept` with the SDP answer and creates the Vapi call: `POST /call` with
   `transport.provider = "vapi.websocket"`, `pcm_s16le`, 16 kHz. It then opens `transport.websocketCallUrl`.
   It never uses `monitor.listenUrl`, which is listen-only.
3. **Accept**, using the same SDP. Audio starts only after accept's 200 OK, as Meta requires. Vapi's greeting
   is already queued, so the caller hears it at once.
4. **Caller to Vapi:** libwebrtc decodes Opus to 48 kHz PCM. The bridge downmixes it, low-passes it,
   decimates it to 16 kHz, and sends it in 20 ms binary frames.
5. **Vapi to caller:** binary PCM goes into a playout queue that releases exactly 10 ms per tick on a
   drift-corrected clock, and silence when there is nothing to say. libwebrtc encodes it to Opus.
   `user-interrupted` (or `clear`) from Vapi empties the queue, so a barge-in cuts the assistant off at once.
6. **Ending:**

   | Trigger | What the bridge does |
   |---|---|
   | Meta `terminate` webhook (caller hung up) | Closes the Vapi socket after `{"type":"end-call"}` |
   | Vapi closes the socket (assistant ended the call) | Sends Meta `terminate` |
   | Media fails or is lost for 15 s | Ends the call |
   | Setup takes longer than 25 s | Rejects the call |
   | Call reaches `VOICE_MAX_CALL_SECONDS` | Ends the call |
   | Bridge shuts down | Ends every call |

   A call that was never accepted is `reject`ed. One that was accepted is `terminate`d, because Meta bills
   until terminate.

The bridge also guards against duplicates and overload:

- **Duplicates:** each Meta call ID is handled once. A retried connect webhook, even one arriving after the
  call ended (remembered for 15 minutes), never starts a second Vapi session.
- **Overload:** above `VOICE_MAX_CALLS`, new calls are rejected as `busy`. Concurrent calls are limited by
  Meta's and Vapi's plans too.
- **Not configured:** while a required setting is missing, calls are rejected rather than left ringing, and
  `/health` lists what's missing.

**n8n workflow 13** ([13-voice-calls.json](../n8n/workflows/13-voice-calls.json), built by
`plan/build_voice_workflow.py`):

- **A. Call webhooks from 06.** Forwards them to the bridge, which needs `x-bridge-secret`, then logs each
  call event through `voice_log_event('meta', …)`. The SDP is not stored.
- **B. `POST /webhook/voice/events`.** Takes lifecycle events from the bridge: `ringing`, `connecting`,
  `active`, `ended`, `failed`, `rejected`. Calls without the bridge secret get 401.
- **C. `POST /webhook/vapi/events`.** Vapi server messages, which must carry `x-vapi-secret`:
  - `tool-calls`: `get_github_projects` reads github.com/Harsh-DevOps117's public repositories.
  - `end-of-call-report`: summary, transcript, cost and duration go to the call's row. Web calls get their
    own row here.

**Workflow 06** sends WhatsApp Trigger items with `field = 'calls'` to 13 before anything treats them as
messages. Its trigger subscribes the Meta app to `messages` and `calls`.

**Postgres** ([015_voice_calls.sql](../db/migrations/015_voice_calls.sql) + `.repeatable.sql`): one row per call
in `public.voice_calls`, with its events in `public.voice_call_events`. A call's state only moves forward,
so late or repeated events never reopen a finished call. View the calls with `SELECT * FROM public.v_voice_calls;`.

## One conversation: the voice agent and the WhatsApp bot (MCP)

The WhatsApp bot (workflow 06, with its Groq LLM) is the only brain. On a call, the voice agent is its voice:

```text
caller ──speaks──► Vapi agent ──message_tori──► web /api/mcp ──signed "WhatsApp message" from the caller──► n8n 06
   ▲                    ▲                                                                                    │
   └──says the reply────┴──── the bot's replies (logged on their way to Meta by web /api/graph) ◄────────────┘
                                                   └──► the same messages in the caller's WhatsApp chat
```

- **What the caller says goes to the bot, as if they had typed it.** The bot decides what happens next: the name
  check, profile questions, a missing time, matching. The agent says the bot's reply, sends the caller's answer
  back, and offers the bot's buttons as choices, so the same steps happen on the call as in the chat.
- **The chat stays in step.** Every bot message also lands in the caller's WhatsApp chat. The first one after
  each thing said on the call starts with it (📞 *On your call: "6 pm"*), so the chat reads as one conversation.
  Anything started on a call can be finished in the chat, and the other way round: the state lives in Postgres.
- **How the agent gets the replies:** n8n's `BOT_WHATSAPP_GRAPH_URL` points at the web app (`/api/graph`, set in
  docker-compose.yml). It passes every request on to the Graph API (`.env`'s `BOT_WHATSAPP_GRAPH_URL`, default
  Meta) unchanged, and logs each sent message with its buttons in `tori_messages` (`direction = 'out'`, `payload`;
  db 018). It never delays or fails a send because of logging. It refuses requests that came through the public
  tunnel. Trade-off: the bot's sends now need the web container to be up (n8n starts after it).

The assistant has one Vapi **MCP** tool, `toriTools`, pointing at the Tori MCP server:
`POST <BOARD_PUBLIC_URL>/api/mcp` ([web/src/app/api/mcp/route.ts](../web/src/app/api/mcp/route.ts),
[web/src/lib/agent.ts](../web/src/lib/agent.ts)). Vapi sends `x-tori-mcp-key: TORI_MCP_KEY` (requests without it
get 401) and `X-Call-Id`.

| Tool | Does |
|---|---|
| `message_tori` `{text}` or `{button_id}` | One turn with the bot: what the caller said, or the button they chose. Returns the bot's replies with their buttons, after waiting up to 15 s for them |
| `check_tori_replies` | Bot messages that arrived since (a slow reply, a match found during the call) |
| `search_open_games` | Open games on the board, with join codes. Works for anyone, also on the website |
| `get_my_status` | A quick look at the caller's requests, matches, cab request and wallet balance |

**Who is calling:** for a WhatsApp call, `X-Call-Id` is the Vapi call ID that voice-bridge logged in `voice_calls`
next to the caller's number. The agent talks to the bot as that person while the call is live (and until 2 minutes
after it ends). Web page (/voice) calls are anonymous: only `search_open_games` works there, and the agent asks
them to call or message Tori on WhatsApp. There are no payment tools, so money never moves by voice. Each call
can take at most 30 turns.

**Setup:** set `TORI_MCP_KEY` in `.env`, then run `scripts/vapi-mcp.sh`. It creates or updates the tool and
attaches it to `VAPI_ASSISTANT_ID`, changing only the assistant's `toolIds`. The board's tunnel address changes
on every restart, so `scripts/board-tunnel.sh` runs it each time. Each tool call is logged:
`docker compose logs web | grep "mcp tool"`.

**Tests:** `E2E_ONLY=mcp scripts/travel-e2e.sh` ([scripts/mcp_e2e.py](../scripts/mcp_e2e.py)). It covers:
- the protocol, the key, and that the pass-through refuses public requests;
- the bot's reply reaching the agent and appearing in the chat with the echo;
- a complete profile set up by voice (joining a game);
- a missing time asked on the call;
- late replies, and ended calls.

The other end-to-end suites now send every bot message through the pass-through too.

## Setup

### 1. Vapi dashboard

- **API Keys → Public key**:
  - Put it in `NEXT_PUBLIC_VAPI_PUBLIC_KEY`.
  - **Restrict it** to your site's origins (`http://localhost:3001`, the board's public address) and to the
    assistant ID.
  - It is meant for browsers; the page receives it at request time.
- **API Keys → Private key**:
  - Put it in `VAPI_PRIVATE_API_KEY`. **Only voice-bridge gets it.**
  - It must never be in a `NEXT_PUBLIC_*` variable or in Git.
  - WhatsApp calls need it: creating a WebSocket-transport call is a private-key operation.
- **Assistant → Server URL** (optional, for tool calls and call logs):
  - URL: `https://<n8n public address>/webhook/vapi/events`.
  - Add a header `x-vapi-secret: <VAPI_SERVER_SECRET>`.
  - Server messages to enable: `end-of-call-report`, `tool-calls`.
  - To send WhatsApp calls' messages there without changing the assistant, set `VAPI_SERVER_URL` instead.
- **Tool** (optional): add a function tool to the assistant so it can list Harsh's projects live:

  ```json
  { "type": "function",
    "function": { "name": "get_github_projects",
                  "description": "List Harsh Kharwar's public GitHub repositories with descriptions and languages.",
                  "parameters": { "type": "object", "properties": {} } },
    "server": { "url": "https://<n8n public address>/webhook/vapi/events",
                "headers": { "x-vapi-secret": "<VAPI_SERVER_SECRET>" } } }
  ```

### 2. Meta

- **Calling** must be enabled on the number, with `"calling":{"status":"ENABLED"}`. It already is on
  +1 555-148-8874. To check:

  ```bash
  curl -s "https://graph.facebook.com/v25.0/$BOT_WHATSAPP_PHONE_NUMBER_ID/settings" -H "Authorization: Bearer $BOT_WHATSAPP_TOKEN"
  ```

- **Webhook field `calls`:** `scripts/bot-tunnel.sh` and workflow 06's trigger subscribe it together with
  `messages`. To check:

  ```bash
  curl -s "https://graph.facebook.com/v25.0/$BOT_META_APP_ID/subscriptions?access_token=$BOT_META_APP_ID|$BOT_META_APP_SECRET"
  ```

- **Token:** use a **System User token** with `whatsapp_business_messaging` and `whatsapp_business_management`
  for `BOT_WHATSAPP_TOKEN`. The temporary token from API Setup lasts 24 hours, and an expired token means
  calls can be neither accepted nor rejected.

### 3. `.env`

```env
NEXT_PUBLIC_VAPI_PUBLIC_KEY=<public key>
VAPI_PRIVATE_API_KEY=<private key>
VAPI_ASSISTANT_ID=afd96ebf-40a7-40d2-bc0b-b6b94367e588
VOICE_BRIDGE_SECRET=<openssl rand -hex 32>
VAPI_SERVER_SECRET=<openssl rand -hex 32>
# Meta: the bot's BOT_WHATSAPP_TOKEN, BOT_WHATSAPP_PHONE_NUMBER_ID, BOT_META_APP_SECRET
```

All settings are described in [.env.example](../.env.example). The `META_ACCESS_TOKEN`,
`META_PHONE_NUMBER_ID` and `META_APP_SECRET` names are accepted as aliases.

### 4. Run

```bash
docker compose up -d --build      # migrations (015), web (/voice), voice-bridge, n8n re-imports 06 + 13
scripts/bot-tunnel.sh             # public n8n address + Meta webhook (messages, calls)
curl -s localhost:8099/health     # {"ok":true,...}; "missing" lists unset settings
```

- **Web:** open http://localhost:3001/voice. Localhost counts as a secure context, so the microphone works.
  For phones, `scripts/board-tunnel.sh` gives an HTTPS address; add that origin to the public key's allowed
  origins.
- **WhatsApp:** call +1 555-148-8874 from WhatsApp. Watch the call with:
  - `docker compose logs -f voice-bridge` (JSON lines, one `call` field per call)
  - `curl -s -H "x-bridge-secret: $VOICE_BRIDGE_SECRET" localhost:8099/calls`
  - `SELECT * FROM public.v_voice_calls;`

## Tests

| Command | Covers |
|---|---|
| `cd voice-bridge && npm test` | 20 tests: resampling (level, anti-aliasing, frame continuity), PCM framing, playout pacing and barge-in, webhook parsing (raw Meta and n8n item), signature check, exact Calling API and Vapi request bodies, duplicates, busy, config. **End to end:** see below |
| `cd web && npm test && npm run typecheck` | transcript merging (partials, finals, overlapping speakers), SDK error messages |
| `psql -v ON_ERROR_STOP=1 -f db/tests/voice_calls.sql` | 13 checks: lifecycle, repeated and late webhooks, two callers, busy, failed calls, Vapi reports |

The end-to-end test runs real WebRTC (libwebrtc, Opus, ICE, DTLS-SRTP over localhost) against fake Meta,
Vapi and n8n servers:

- Two callers are on at once, each speaking its own tone, and each fake Vapi answers with its own tone.
- Frequency analysis checks that audio arrives both ways and never crosses between calls.
- A third caller is rejected as busy.
- A retried webhook is ignored.
- Hang-ups are tested from both sides.
- A Vapi outage rejects the call.

The tests run inside the Docker image too:

```bash
docker run --rm -v "$PWD/voice-bridge/test:/app/test:ro,z" tori-voice-bridge sh -c 'node --test --test-force-exit test/*.test.js'
```

`--test-force-exit` is there because libwebrtc segfaults when Node exits by itself with the module loaded.
`process.exit()` is clean, and the server always exits that way. 200 create/destroy cycles in one process
were stable.

## Deploying

- The bridge needs **outbound UDP** to Meta's media servers. ICE works through NAT with STUN, so there are no
  inbound ports to open. If ICE fails behind a strict or symmetric NAT, run the bridge with
  `network_mode: host`. In that case set `VOICE_EVENTS_URL=http://localhost:5678/webhook/voice/events`.
  Alternatively, put it on a host with a public IP.
- n8n needs a stable HTTPS address for Meta and Vapi. A quick tunnel's address changes on every restart, and
  quick tunnels can disappear: re-run `scripts/bot-tunnel.sh`.
- The bridge holds calls in memory, so run one replica. Restarting it ends the active calls.
- **Load:**
  - CPU: Opus runs natively in libwebrtc. In JavaScript, each call only runs a 63-tap filter evaluated at
    16 kHz. CPU per call has not been measured under real load.
  - Memory: about 35 MB at idle.
  - Raise `VOICE_MAX_CALLS` within your Vapi concurrency limit.

## Troubleshooting

| Symptom | Look at | Likely cause / fix |
|---|---|---|
| The call rings, then "Not answered" | `docker compose logs voice-bridge` | Nothing logged: the webhook never arrived. Check the subscription fields include `calls`, that n8n is public (`bot-tunnel.sh`), and that 06 is published. `rejected_not_configured`: `/health` → `missing`. |
| `Meta pre_accept failed (401)` / `190` | bridge log | `BOT_WHATSAPP_TOKEN` expired. Use a System User token, then `docker compose up -d`. |
| `Meta accept failed … SDP` | bridge log | Accept must carry the pre_accept SDP (the bridge does this). A rejected answer means Meta disliked the libwebrtc SDP: send `docker compose logs voice-bridge` with `VOICE_LOG_LEVEL=debug`. |
| `Vapi call create failed (401)` | bridge log | `VAPI_PRIVATE_API_KEY` is wrong, or is the public key. |
| `Vapi call create failed (400)` | bridge log | The message names the field. Check `VAPI_ASSISTANT_ID`, and that the plan allows WebSocket calls. |
| Connected, silence both ways, then `media_timeout` / `media_lost` | bridge log: `media state` | ICE/DTLS never completed: UDP is blocked, or NAT. Try `network_mode: host`, another `VOICE_STUN_URLS`, or a public host. |
| The caller hears the assistant, but the assistant doesn't hear them | `/calls` → `to_vapi_kb`, `caller_frames` | `caller_frames` = 0: no inbound RTP (firewall). Frames but no reply: check the Vapi dashboard call log for transcription. |
| The assistant keeps talking after being interrupted | `/calls` → `control` | Vapi did not send `user-interrupted` on the socket. Enable it in the assistant's *client messages*. The bridge then clears its playout queue at once. |
| Calls refused as busy | `/health` → `active` | Raise `VOICE_MAX_CALLS`, within your Vapi concurrency. |
| Web: "refused this site's key" | browser console `[vapi]` | Wrong `NEXT_PUBLIC_VAPI_PUBLIC_KEY`, or the page's origin is not allowed on the key. |
| Web: microphone blocked | | Allow the mic in the address bar. The page must be HTTPS or localhost. |
| No rows in `voice_calls` | n8n → Executions → workflow 13 | `VOICE_BRIDGE_SECRET` / `VAPI_SERVER_SECRET` differ between `.env` and the sender (401 in the execution). |
| Workflow 06's trigger shows "Trigger On: invalid value" in the editor | | `calls` is not in n8n 2.41's dropdown, but it is passed to Meta as is. Edit 06 through `plan/build_partner_workflow.py`, which re-adds the hook. Saving from the UI may drop `calls`. |

## Status

Verified locally:

- The web page renders, and the transcript logic passes its tests.
- The bridge passes its tests on the host and in its Docker image.
- A Meta-signed `calls` webhook goes through n8n 06 → 13 → the bridge → Postgres.
- The bridge-event and Vapi webhooks work, including the 401s, the GitHub tool and the end-of-call report.

**Not yet verified:**

- A real WhatsApp call through Meta's media servers. That needs `VAPI_PRIVATE_API_KEY` and a valid Meta token.
- A real browser conversation, which needs someone at a microphone.

Until a real call is accepted, audio is heard both ways, and the call ends cleanly, WhatsApp calling is
implemented and tested against simulations only.
