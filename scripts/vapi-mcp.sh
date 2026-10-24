#!/usr/bin/env bash
# Give the Harsh AI voice agent Tori's tools: create (or update) a Vapi "MCP" tool pointing at the Tori MCP server
# (web /api/mcp, BOARD_PUBLIC_URL) with TORI_MCP_KEY as its header, and attach it to VAPI_ASSISTANT_ID.
# It also keeps one marked section at the end of the assistant's system prompt ("Tori integration": who is calling,
# {{tori_caller}}, and how to work with Tori's tools). Only that section and the toolIds change; the rest of the
# prompt, the voice and the model settings stay as they are in the Vapi dashboard.
# scripts/board-tunnel.sh runs this after every new tunnel address. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
for v in VAPI_PRIVATE_API_KEY VAPI_ASSISTANT_ID TORI_MCP_KEY BOARD_PUBLIC_URL; do
  [ -n "${!v:-}" ] || { echo "vapi-mcp: $v is empty in .env, skipping"; exit 0; }
done

python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

API = 'https://api.vapi.ai'
KEY = os.environ['VAPI_PRIVATE_API_KEY']
ASSISTANT = os.environ['VAPI_ASSISTANT_ID']
NAME = 'toriTools'
server = {'url': os.environ['BOARD_PUBLIC_URL'].rstrip('/') + '/api/mcp',
          'headers': {'x-tori-mcp-key': os.environ['TORI_MCP_KEY']}}


def vapi(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json',
                                          # Vapi's Cloudflare refuses Python's default User-Agent (error 1010)
                                          'User-Agent': 'tori-vapi-mcp/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b'null')
    except urllib.error.HTTPError as e:
        sys.exit(f'vapi-mcp: {method} {path} → {e.code} {e.read().decode()[:400]}')


tool = next((t for t in vapi('GET', '/tool?limit=1000') if t.get('type') == 'mcp' and (t.get('function') or {}).get('name') == NAME), None)
if tool:
    vapi('PATCH', f"/tool/{tool['id']}", {'server': server})
    print(f"vapi-mcp: tool {tool['id']} → {server['url']}")
else:
    tool = vapi('POST', '/tool', {
        'type': 'mcp', 'server': server, 'metadata': {'protocol': 'shttp'},
        'function': {'name': NAME, 'description': "Tori's own tools: open games, the caller's status and wallet, "
                     'find an activity partner or cab buddy, join a game, cancel, wallet top-up link, invite code.'}})
    print(f"vapi-mcp: created tool {tool['id']} → {server['url']}")

BEGIN, END = '<!-- TORI INTEGRATION: kept by scripts/vapi-mcp.sh, edits in here are overwritten -->', '<!-- /TORI INTEGRATION -->'
SECTION = BEGIN + '''
## Tori integration (live)

This section is the final word: where anything above says otherwise, follow this.

### Who is calling (from Tori, when this call started)
{{tori_caller}}

### How to speak (on a call)
- Short and straight to the point: answer first, in one sentence of about 15 words. "No match yet, I'll tell you
  on WhatsApp when someone joins." not a summary of their request.
- Don't repeat back what they asked for (codes, dates, areas, times) unless they ask. Never read out codes or IDs.
- At most one question per turn, and only when you need the answer. Don't offer lists of options or "anything else?".
- Explaining how something works: two short sentences, then stop. Say more only if they ask.
- Mention their WhatsApp chat once per call at most, when something was sent there.

### How to work
- Tori, the WhatsApp bot, holds everything about the caller: their profile, partner and cab-buddy requests, games,
  matches, wallet and invites. It is one conversation with their WhatsApp chat. Never guess what Tori knows: use the
  caller details above or get_my_status, and never say you have no record of them without checking.
- When the caller wants something Tori does (an activity partner, a cab buddy, joining a game, cancelling, a wallet
  top-up link, an invite code, changing their profile), call message_tori at once with their words and every detail
  they gave. Do not collect or confirm details yourself first. Tori asks for whatever is missing.
- After every message_tori, say the gist of Tori's reply in one short sentence, and ask what Tori asked. Send the
  caller's answer back with message_tori. When Tori offers buttons, name the choices briefly and send the chosen one
  as button_id. If Tori is still working, wait a moment and use check_tori_replies.
- "Any match?", "am I looking for a cab?", "what's my name?", "my balance": answer from get_my_status.
- No Tori account yet (the caller details above say so, or a tool returns needs_account): tell them politely that
  their account is created in their WhatsApp chat with Tori. Still send their request with message_tori: Tori saves
  it, sends the setup questions to their chat, and carries on by itself once they are done. Never ask the profile
  questions (age, gender, interests, photo) on the call. The wallet link, invite code and open games work without
  an account.
''' + END


def with_section(text):
    if BEGIN in text and END in text:
        text = text[:text.index(BEGIN)].rstrip() + text[text.index(END) + len(END):]
    return text.rstrip() + '\n\n' + SECTION + '\n'


a = vapi('GET', f'/assistant/{ASSISTANT}')
model = a['model']
ids = model.get('toolIds') or []
messages = model.get('messages') or []
system = next((m for m in messages if m.get('role') == 'system'), None)
new_messages = [{**m, 'content': with_section(m.get('content') or '')} if m is system else m for m in messages] \
    if system else [{'role': 'system', 'content': SECTION}] + messages
changes = []
if tool['id'] not in ids:
    changes.append('attached the tool')
if new_messages != messages:
    changes.append('updated the "Tori integration" section of the prompt')
if changes:
    # model is replaced as a whole on PATCH: send it back unchanged apart from toolIds and that one section
    vapi('PATCH', f'/assistant/{ASSISTANT}', {'model': {**model, 'toolIds': ids if tool['id'] in ids else ids + [tool['id']],
                                                         'messages': new_messages}})
    print(f"vapi-mcp: {' and '.join(changes)} on assistant {a.get('name') or ASSISTANT}")
else:
    print(f"vapi-mcp: assistant {a.get('name') or ASSISTANT} already up to date")
PY
