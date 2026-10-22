#!/usr/bin/env python3
"""Generate workflow 13 (Harsh AI voice calls) and hook WhatsApp calls into workflow 06.

    python3 plan/build_voice_workflow.py

Writes n8n/workflows/13-voice-calls.json and adds the call hook to n8n/workflows/06-whatsapp-bot.json
(build_partner_workflow.py adds the same hook when it rebuilds 06, through add_call_hook()).

n8n is the control plane only. Audio runs in voice-bridge/ (WebRTC ↔ Vapi WebSocket), never through n8n:

    Meta `calls` webhook ─► 06 WhatsApp Trigger ─► 13 ─► voice-bridge POST /calls/event   (+ log)
    voice-bridge ─► POST /webhook/voice/events ─► 13 ─► voice_log_event()                (lifecycle)
    Vapi server URL ─► POST /webhook/vapi/events ─► 13 ─► tool calls (GitHub) · end-of-call report
"""
import json
import uuid
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'n8n' / 'workflows'
WF_ID = 'toriVoiceCalls01'
CRED_PG = {'postgres': {'id': 'xzG9f2LEMKhGXmqg', 'name': 'Postgres account'}}  # the bot's database
GITHUB_USER = 'Harsh-DevOps117'

nodes, conns = {}, {}


def nid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f'tori/{WF_ID}/{name}'))


def add(name, type_, version, params, col, row, **extra):
    assert name not in nodes, name
    nodes[name] = {'parameters': params, 'id': nid(name), 'name': name, 'type': type_,
                   'typeVersion': version, 'position': [260 * col, 200 * row], **extra}
    return name


def link(src, dst, out=0):
    outs = conns.setdefault(src, {}).setdefault('main', [])
    while len(outs) <= out:
        outs.append([])
    outs[out].append({'node': dst, 'type': 'main', 'index': 0})


def chain(*names):
    for a, b in zip(names, names[1:]):
        link(a, b)


def code(js):
    return {'mode': 'runOnceForAllItems', 'jsCode': js.strip() + '\n'}


def sql(query, params):
    return {'operation': 'executeQuery', 'query': query.strip(), 'options': {'queryReplacement': '={{ ' + params + ' }}'}}


def bool_if(name, expr, ids=nid):
    return {
        'conditions': {
            'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose', 'version': 2},
            'conditions': [{'id': ids(name + '/cond'), 'leftValue': '={{ ' + expr + ' }}', 'rightValue': '',
                            'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
            'combinator': 'and',
        },
        'looseTypeValidation': True,
        'options': {},
    }


def webhook(name, path, col, row):
    return add(name, 'n8n-nodes-base.webhook', 2.1,
               {'httpMethod': 'POST', 'path': path, 'responseMode': 'responseNode', 'options': {}},
               col, row, webhookId=nid(name + '/hook'))


def respond(name, body, col, row, status=200):
    return add(name, 'n8n-nodes-base.respondToWebhook', 1.4,
               {'respondWith': 'json', 'responseBody': '={{ ' + body + ' }}', 'options': {'responseCode': status}}, col, row)


# ── A. Meta call events, handed over by workflow 06 ─────────────────────────────────────────────────
add('Call webhook from 06', 'n8n-nodes-base.executeWorkflowTrigger', 1.1, {'inputSource': 'passthrough'}, 0, 0)
# first, so the call is answered as fast as possible; the bridge replies at once and answers the call itself
add('Forward to voice bridge', 'n8n-nodes-base.httpRequest', 4.2, {
    'method': 'POST',
    'url': "={{ ($env.VOICE_BRIDGE_URL || 'http://voice-bridge:8099') + '/calls/event' }}",
    'sendHeaders': True,
    'headerParameters': {'parameters': [{'name': 'x-bridge-secret', 'value': '={{ $env.VOICE_BRIDGE_SECRET }}'}]},
    'sendBody': True, 'contentType': 'json', 'specifyBody': 'json',
    'jsonBody': '={{ JSON.stringify($json) }}',
    'options': {'timeout': 10000, 'response': {'response': {'fullResponse': True, 'neverError': True}}},
}, 1, 0, onError='continueRegularOutput')
add('One row per call event', 'n8n-nodes-base.code', 2, code('''
// value.calls[] (+ the caller in value.contacts[0]) → one item per call event, with what the bridge did
const out = [];
const hooks = $('Call webhook from 06').all();
$input.all().forEach((res, i) => {
  const v = hooks[i]?.json || {};
  const handled = res.json.body?.handled || [];
  const contact = (v.contacts || [])[0] || {};
  for (const c of v.calls || []) {
    out.push({ json: { ev: {
      ...c,
      wa_id: c.from || c.from_user_id || contact.wa_id || contact.user_id || null,
      name: contact.profile?.name || null,
      errors: v.errors || c.errors,
      bridge: handled.find((h) => h.id === c.id)?.result || (res.json.statusCode ? `http_${res.json.statusCode}` : 'unreachable'),
    } } });
  }
});
return out;
'''), 2, 0)
add('Log Meta call event', 'n8n-nodes-base.postgres', 2.6,
    sql('SELECT public.voice_log_event($1, $2::jsonb) AS res;', "[ 'meta', JSON.stringify($json.ev) ]"),
    3, 0, credentials=CRED_PG, onError='continueRegularOutput')
chain('Call webhook from 06', 'Forward to voice bridge', 'One row per call event', 'Log Meta call event')

# ── B. Lifecycle from the bridge ─────────────────────────────────────────────────────────────────────
webhook('Bridge events (webhook)', 'voice/events', 0, 2)
add('From the bridge?', 'n8n-nodes-base.if', 2.2,
    bool_if('From the bridge?', "!!$env.VOICE_BRIDGE_SECRET && $json.headers['x-bridge-secret'] === $env.VOICE_BRIDGE_SECRET"), 1, 2)
add('Log bridge event', 'n8n-nodes-base.postgres', 2.6,
    sql('SELECT public.voice_log_event($1, $2::jsonb) AS res;', "[ 'bridge', JSON.stringify($json.body) ]"),
    2, 2, credentials=CRED_PG, onError='continueRegularOutput')
respond('Bridge event logged', '$json.res || { ok: false }', 3, 2)
respond('Bridge refused', "{ error: 'unauthorized' }", 2, 3, status=401)
chain('Bridge events (webhook)', 'From the bridge?', 'Log bridge event', 'Bridge event logged')
link('From the bridge?', 'Bridge refused', 1)

# ── C. Vapi server messages (the assistant's Server URL): tool calls and end-of-call reports ─────────
# Web calls use the URL set on the assistant in the Vapi dashboard; WhatsApp calls use it too, or
# VAPI_SERVER_URL on the bridge. Vapi must send the header x-vapi-secret: $env.VAPI_SERVER_SECRET.
webhook('Vapi server messages (webhook)', 'vapi/events', 0, 5)
add('From Vapi?', 'n8n-nodes-base.if', 2.2,
    bool_if('From Vapi?', "!!$env.VAPI_SERVER_SECRET && $json.headers['x-vapi-secret'] === $env.VAPI_SERVER_SECRET"), 1, 5)
add('Message type', 'n8n-nodes-base.switch', 3.2, {
    'mode': 'expression', 'numberOutputs': 3,
    'output': "={{ ['tool-calls', 'end-of-call-report'].includes($json.body?.message?.type) "
              "? ['tool-calls', 'end-of-call-report'].indexOf($json.body.message.type) : 2 }}",
}, 2, 5)
respond('Vapi refused', "{ error: 'unauthorized' }", 2, 7, status=401)
link('Vapi server messages (webhook)', 'From Vapi?')
link('From Vapi?', 'Message type')
link('From Vapi?', 'Vapi refused', 1)

# tool calls: get_github_projects reads Harsh's public GitHub repositories
add('GitHub · public repos', 'n8n-nodes-base.httpRequest', 4.2, {
    'method': 'GET',
    'url': f'https://api.github.com/users/{GITHUB_USER}/repos?sort=updated&per_page=15&type=owner',
    'sendHeaders': True,
    'headerParameters': {'parameters': [{'name': 'accept', 'value': 'application/vnd.github+json'},
                                        {'name': 'user-agent', 'value': 'tori-voice'}]},
    'options': {'timeout': 8000, 'response': {'response': {'fullResponse': True, 'neverError': True}}},
}, 3, 4, onError='continueRegularOutput')
add('Answer tool calls', 'n8n-nodes-base.code', 2, code('''
// Vapi expects { results: [{ toolCallId, name, result }] }, result as a string, for every tool call it sent
const msg = $('Message type').first().json.body.message;
const calls = msg.toolCallList || msg.toolCalls || (msg.toolWithToolCallList || []).map((t) => t.toolCall) || [];
const gh = $input.first().json;
const repos = gh.statusCode === 200 && Array.isArray(gh.body) ? gh.body.filter((r) => !r.fork) : null;
const projects = () => {
  if (!repos) return 'GitHub could not be reached right now. His profile is github.com/''' + GITHUB_USER + '''.';
  return repos.slice(0, 10).map((r) => [
    r.name, r.description || 'no description', r.language ? `written mostly in ${r.language}` : '',
    r.stargazers_count ? `${r.stargazers_count} stars` : '', `updated ${String(r.pushed_at || '').slice(0, 10)}`,
  ].filter(Boolean).join(', ')).join('\\n');
};
const results = calls.map((c) => {
  const name = c.function?.name || c.name;
  const result = name === 'get_github_projects' ? projects() : `Unknown tool ${name}.`;
  return { toolCallId: c.id, name, result };
});
return [{ json: { results } }];
'''), 4, 4)
respond('Tool results', 'JSON.stringify($json)', 5, 4)
link('Message type', 'GitHub · public repos', 0)
chain('GitHub · public repos', 'Answer tool calls', 'Tool results')

add('Log end-of-call report', 'n8n-nodes-base.postgres', 2.6,
    sql('SELECT public.voice_log_report($1::jsonb) AS res;', 'JSON.stringify($json.body.message)'),
    3, 5, credentials=CRED_PG, onError='continueRegularOutput')
respond('Report logged', '{ ok: true }', 4, 5)
link('Message type', 'Log end-of-call report', 1)
chain('Log end-of-call report', 'Report logged')
respond('Other message: ok', '{ ok: true }', 3, 6)
link('Message type', 'Other message: ok', 2)


def write_13():
    for src, by_type in conns.items():
        assert src in nodes, src
        for outs in by_type.values():
            for out in outs:
                for c in out:
                    assert c['node'] in nodes, f'{src} -> {c["node"]}'
    wf = {
        'id': WF_ID, 'name': 'Tori 13 · Voice calls (WhatsApp → Harsh AI)',
        'description': 'Control plane for Harsh AI voice calls: forwards WhatsApp call webhooks (from 06) to '
                       'voice-bridge, logs the call lifecycle, answers Vapi tool calls and stores end-of-call '
                       'reports. Audio never passes through n8n.',
        'nodes': list(nodes.values()), 'connections': conns,
        'settings': {'executionOrder': 'v1', 'saveManualExecutions': True,
                     'callerPolicy': 'workflowsFromSameOwner', 'timezone': 'Asia/Kolkata'},
        'pinData': {}, 'tags': [], 'active': False,
    }
    path = OUT / '13-voice-calls.json'
    path.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + '\n')
    print(f'wrote n8n/workflows/13-voice-calls.json ({len(nodes)} nodes)')


def add_call_hook(wf):
    """Workflow 06: subscribe the WhatsApp Trigger to `calls` too, and send call events to 13 before
    anything treats them as messages. Safe to run again on a workflow that already has the hook."""
    by = {n['name']: n for n in wf['nodes']}
    c = wf['connections']
    trig = by['WhatsApp Trigger']
    # 'calls' is not in the node's dropdown (n8n 2.41) but the trigger registers whatever is listed with Meta
    updates = trig['parameters'].setdefault('updates', [])
    if 'calls' not in updates:
        updates.append('calls')
    if 'Call event?' in by:
        return
    x, y = trig['position']
    first = c['WhatsApp Trigger']['main'][0]          # what used to run first ("Log inbound message")

    def hook_id(name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f'tori/toriWhatsAppBot1/{name}'))

    wf['nodes'].append({
        'parameters': bool_if('Call event?', "$json.field === 'calls'", ids=hook_id),
        'id': hook_id('Call event?'), 'name': 'Call event?', 'type': 'n8n-nodes-base.if', 'typeVersion': 2.2,
        'position': [x, y + 220],
    })
    wf['nodes'].append({
        'parameters': {'workflowId': {'__rl': True, 'mode': 'id', 'value': WF_ID}, 'options': {'waitForSubWorkflow': False}},
        'id': hook_id('Voice call (13)'), 'name': 'Voice call (13)', 'type': 'n8n-nodes-base.executeWorkflow',
        'typeVersion': 1.2, 'position': [x + 260, y + 220], 'onError': 'continueRegularOutput',
    })
    c['WhatsApp Trigger'] = {'main': [[{'node': 'Call event?', 'type': 'main', 'index': 0}]]}
    c['Call event?'] = {'main': [[{'node': 'Voice call (13)', 'type': 'main', 'index': 0}], first]}


if __name__ == '__main__':
    write_13()
    p06 = OUT / '06-whatsapp-bot.json'
    wf06 = json.loads(p06.read_text())
    before = len(wf06['nodes'])
    add_call_hook(wf06)
    p06.write_text(json.dumps(wf06, indent=2, ensure_ascii=False) + '\n')
    print(f'n8n/workflows/06-whatsapp-bot.json: call hook ({len(wf06["nodes"]) - before} nodes added)')
