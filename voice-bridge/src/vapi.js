'use strict';
// Vapi WebSocket transport: one Vapi call per WhatsApp call, created with the private API key, then a
// WebSocket to transport.websocketCallUrl that carries raw PCM both ways (binary frames) and JSON control
// messages (text frames). https://docs.vapi.ai/calls/websocket-transport
// Not monitor.listenUrl: that one is listen-only.

class VapiError extends Error {
  constructor(status, body) {
    super(`Vapi call create failed (${status}): ${body?.message ? [].concat(body.message).join('; ') : JSON.stringify(body)}`);
    this.status = status;
  }
}

function vapiClient({ apiUrl = 'https://api.vapi.ai', privateKey, assistantId, sampleRate = 16000, serverUrl, serverSecret,
                      fetchImpl = fetch, timeoutMs = 10000 }) {
  return {
    // → { id, websocketCallUrl }
    async createCall({ metaCallId, waId, name }) {
      const overrides = {
        // the dashboard assistant stays as configured; this only tags the call and names the caller
        variableValues: { callerName: name || '', channel: 'whatsapp' },
        metadata: { channel: 'whatsapp', metaCallId, waId },
      };
      if (serverUrl) overrides.server = { url: serverUrl, ...(serverSecret ? { headers: { 'x-vapi-secret': serverSecret } } : {}) };
      const res = await fetchImpl(`${apiUrl}/call`, {
        method: 'POST',
        headers: { authorization: `Bearer ${privateKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          assistantId,
          assistantOverrides: overrides,
          ...(name || waId ? { customer: { ...(name ? { name } : {}), ...(waId ? { externalId: waId } : {}) } } : {}),
          transport: { provider: 'vapi.websocket', audioFormat: { format: 'pcm_s16le', container: 'raw', sampleRate } },
        }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new VapiError(res.status, body);
      const url = body?.transport?.websocketCallUrl;
      if (!url) throw new VapiError(res.status, { message: 'no transport.websocketCallUrl in the response' });
      return { id: body.id, websocketCallUrl: url };
    },
  };
}

module.exports = { vapiClient, VapiError };
