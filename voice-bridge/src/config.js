'use strict';
// Settings from the environment. Names follow the rest of the repo (BOT_* for the WhatsApp bot's Meta app);
// the META_* names from the setup guide work too.

function loadConfig(env = process.env) {
  const pick = (...keys) => keys.map((k) => env[k]).find((v) => v !== undefined && v !== '') || '';
  const num = (k, d) => (env[k] ? Number(env[k]) : d);
  const cfg = {
    port: num('PORT', 8099),
    secret: pick('VOICE_BRIDGE_SECRET'),
    meta: {
      graphUrl: pick('VOICE_GRAPH_URL') || 'https://graph.facebook.com/v25.0',
      token: pick('META_ACCESS_TOKEN', 'BOT_WHATSAPP_TOKEN'),
      phoneNumberId: pick('META_PHONE_NUMBER_ID', 'BOT_WHATSAPP_PHONE_NUMBER_ID'),
      appSecret: pick('META_APP_SECRET', 'BOT_META_APP_SECRET'),
      verifyToken: pick('META_VERIFY_TOKEN'),
    },
    vapi: {
      apiUrl: pick('VAPI_API_URL') || 'https://api.vapi.ai',
      privateKey: pick('VAPI_PRIVATE_API_KEY'),
      assistantId: pick('VAPI_ASSISTANT_ID') || 'afd96ebf-40a7-40d2-bc0b-b6b94367e588',
      sampleRate: num('VOICE_VAPI_SAMPLE_RATE', 16000),
      serverUrl: pick('VAPI_SERVER_URL'),
      serverSecret: pick('VAPI_SERVER_SECRET'),
      // who is calling, from Tori (web /api/agent/context), for the assistant's prompt
      contextUrl: pick('TORI_CONTEXT_URL') || 'http://web:3000/api/agent/context',
      contextKey: pick('TORI_MCP_KEY'),
    },
    eventsUrl: pick('VOICE_EVENTS_URL'),
    maxCalls: num('VOICE_MAX_CALLS', 5),
    session: {
      maxCallSeconds: num('VOICE_MAX_CALL_SECONDS', 900),
      setupTimeoutMs: num('VOICE_SETUP_TIMEOUT_MS', 25000),
      iceServers: (pick('VOICE_STUN_URLS') || 'stun:stun.l.google.com:19302')
        .split(',').map((s) => s.trim()).filter(Boolean).map((urls) => ({ urls })),
    },
  };
  const missing = [];
  if (!cfg.secret) missing.push('VOICE_BRIDGE_SECRET');
  if (!cfg.meta.token) missing.push('BOT_WHATSAPP_TOKEN (or META_ACCESS_TOKEN)');
  if (!cfg.meta.phoneNumberId) missing.push('BOT_WHATSAPP_PHONE_NUMBER_ID (or META_PHONE_NUMBER_ID)');
  if (!cfg.vapi.privateKey) missing.push('VAPI_PRIVATE_API_KEY');
  return { cfg, missing };
}

module.exports = { loadConfig };
