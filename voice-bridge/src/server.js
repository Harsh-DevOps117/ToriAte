'use strict';
// Entry point: real WebRTC (libwebrtc via @roamhq/wrtc), real Meta and Vapi clients.
const wrtc = require('@roamhq/wrtc');
const WebSocket = require('ws');
const { loadConfig } = require('./config');
const { metaCalls } = require('./meta');
const { vapiClient } = require('./vapi');
const { createBridge } = require('./bridge');

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const minLevel = LEVELS[process.env.LOG_LEVEL || 'info'] || 20;
function log(level, msg, fields = {}) {
  if ((LEVELS[level] || 20) < minLevel) return;
  console.log(JSON.stringify({ t: new Date().toISOString(), level, msg, ...fields }));
}

const { cfg, missing } = loadConfig();
if (missing.length) log('warn', 'bridge is not configured: incoming calls will be rejected', { missing });

const bridge = createBridge(cfg, {
  rtc: { RTCPeerConnection: wrtc.RTCPeerConnection, RTCAudioSource: wrtc.nonstandard.RTCAudioSource, RTCAudioSink: wrtc.nonstandard.RTCAudioSink },
  meta: metaCalls(cfg.meta),
  vapi: vapiClient(cfg.vapi),
  WebSocket,
  log,
}, missing);

bridge.server.listen(cfg.port, () => log('info', 'voice bridge listening', { port: cfg.port, max_calls: cfg.maxCalls }));

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, async () => {
    log('info', 'shutting down: ending active calls', { active: bridge.registry.size });
    const t = setTimeout(() => process.exit(1), 8000);
    await bridge.shutdown().catch(() => {});
    clearTimeout(t);
    process.exit(0);
  });
}
