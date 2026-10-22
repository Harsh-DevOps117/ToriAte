'use strict';
// One WhatsApp call ↔ one Vapi call. Everything a call owns lives here (peer connection, audio source and
// sink, resampler, playout queue, Vapi socket, timers), so calls never share audio or context.
//
//   connect webhook (SDP offer)
//     → answer the offer (non-trickle: wait for ICE gathering, Meta takes one SDP)
//     → pre_accept (media path comes up)   ┐ in parallel
//     → create the Vapi call + open its WS ┘
//     → accept (same SDP) → audio both ways
//   ends on: Meta terminate webhook, Vapi closing the socket, media failure, timeouts, bridge shutdown.

const { EventEmitter } = require('node:events');
const { Resampler, PcmDecoder, PlayoutQueue, downmix, toBytes } = require('./audio');

const VAPI_RATE_DEFAULT = 16000;
const SEND_EVERY_MS = 20; // caller audio goes to Vapi in 20 ms chunks

function waitIceGathering(pc, timeoutMs) {
  if (pc.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => { clearTimeout(t); pc.removeEventListener?.('icegatheringstatechange', check); resolve(); };
    const check = () => pc.iceGatheringState === 'complete' && done();
    const t = setTimeout(done, timeoutMs); // go with the candidates we have
    if (pc.addEventListener) pc.addEventListener('icegatheringstatechange', check);
    else pc.onicegatheringstatechange = check;
  });
}

function withTimeout(promise, ms, what) {
  let t;
  return Promise.race([
    promise,
    new Promise((_, reject) => { t = setTimeout(() => reject(new Error(`${what} timed out after ${ms} ms`)), ms); }),
  ]).finally(() => clearTimeout(t));
}

class CallSession extends EventEmitter {
  /**
   * @param call  one entry of meta.callEvents(): { id, from, name, sdp }
   * @param deps  { rtc: {RTCPeerConnection, RTCAudioSource, RTCAudioSink}, meta, vapi, WebSocket, report, log }
   * @param cfg   { iceServers, sampleRate, iceGatherMs, setupTimeoutMs, vapiConnectMs, maxCallSeconds, mediaTimeoutMs }
   */
  constructor(call, deps, cfg) {
    super();
    this.id = call.id;
    this.from = call.from;
    this.name = call.name;
    this.offer = call.sdp;
    this.deps = deps;
    this.cfg = { sampleRate: VAPI_RATE_DEFAULT, iceGatherMs: 2500, setupTimeoutMs: 25000, vapiConnectMs: 10000,
                 maxCallSeconds: 900, mediaTimeoutMs: 15000, ...cfg };
    this.state = 'new';          // new → connecting → active → ended | failed
    this.createdAt = Date.now();
    this.answeredAt = null;
    this.vapiCallId = null;
    this.accepted = false;
    this.ended = false;
    this.timers = new Set();
    this.stats = { toVapiBytes: 0, fromVapiBytes: 0, callerFrames: 0, controlTypes: {} };

    this.decoder = new PcmDecoder();
    this.resampler = null;       // made on the first caller frame, when its sample rate is known
    this.pending = [];           // caller audio not yet sent to Vapi
    this.pendingLen = 0;
    this.playout = new PlayoutQueue({ sampleRate: this.cfg.sampleRate, onFrame: (s) => this.#toCaller(s) });
  }

  log(level, msg, extra = {}) { this.deps.log(level, msg, { call: this.id, vapi: this.vapiCallId, ...extra }); }

  #timer(ms, fn) {
    const t = setTimeout(() => { this.timers.delete(t); fn(); }, ms);
    this.timers.add(t);
    return t;
  }

  #report(event, extra = {}) {
    this.deps.report({ event, meta_call_id: this.id, vapi_call_id: this.vapiCallId, wa_id: this.from, name: this.name, ...extra });
  }

  async start() {
    this.state = 'connecting';
    this.#timer(this.cfg.setupTimeoutMs, () => !this.accepted && this.end('failed', 'setup_timeout'));
    try {
      const sdp = await this.#answerOffer();
      if (this.ended) return;
      await Promise.all([
        this.deps.meta.preAccept(this.id, sdp).then(() => this.log('info', 'pre_accepted')),
        this.#connectVapi(),
      ]);
      if (this.ended) return;
      this.#report('connecting');
      await this.deps.meta.accept(this.id, sdp, this.vapiCallId ? `vapi:${this.vapiCallId}` : undefined);
      if (this.ended) return;   // hung up while we were accepting
      this.accepted = true;
      this.answeredAt = Date.now();
      this.state = 'active';
      this.log('info', 'accepted', { setup_ms: this.answeredAt - this.createdAt });
      this.#report('active');
      // Meta: send media only after accept's 200 OK. The greeting Vapi already sent is queued and plays now.
      this.playout.start();
      this.#timer(this.cfg.maxCallSeconds * 1000, () => this.end('ended', 'max_duration'));
      if (this.pc.connectionState !== 'connected') {
        this.#timer(this.cfg.mediaTimeoutMs, () => this.pc?.connectionState !== 'connected' && this.end('failed', 'media_timeout'));
      }
    } catch (err) {
      this.log('error', 'call setup failed', { error: err.message });
      await this.end('failed', err.message.slice(0, 300));
    }
  }

  async #answerOffer() {
    const { RTCPeerConnection, RTCAudioSource, RTCAudioSink } = this.deps.rtc;
    const pc = new RTCPeerConnection({ iceServers: this.cfg.iceServers || [] });
    this.pc = pc;
    pc.ontrack = (e) => {
      if (e.track.kind !== 'audio' || this.sink) return;
      this.sink = new RTCAudioSink(e.track);
      this.sink.ondata = (d) => this.#fromCaller(d);
    };
    pc.onconnectionstatechange = () => this.#onConnectionState(pc.connectionState);
    await pc.setRemoteDescription({ type: 'offer', sdp: this.offer });
    this.source = new RTCAudioSource();
    this.track = this.source.createTrack();
    pc.addTrack(this.track);
    await pc.setLocalDescription(await pc.createAnswer());
    await waitIceGathering(pc, this.cfg.iceGatherMs);
    return pc.localDescription.sdp;
  }

  #onConnectionState(s) {
    this.log('info', 'media state', { state: s });
    if (this.ended) return;
    if (s === 'failed') this.end('failed', 'media_failed');
    else if (s === 'disconnected') {
      clearTimeout(this.dropTimer);
      this.dropTimer = this.#timer(this.cfg.mediaTimeoutMs, () => this.pc?.connectionState !== 'connected' && this.end('failed', 'media_lost'));
    }
  }

  async #connectVapi() {
    const { id, websocketCallUrl } = await this.deps.vapi.createCall({ metaCallId: this.id, waId: this.from, name: this.name });
    this.vapiCallId = id;
    this.log('info', 'vapi call created');
    if (this.ended) return;
    const ws = new this.deps.WebSocket(websocketCallUrl);
    this.ws = ws;
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        this.stats.fromVapiBytes += data.length;
        this.playout.push(this.decoder.push(data));
      } else {
        this.#control(data.toString());
      }
    });
    await withTimeout(new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
      ws.once('close', (code) => reject(new Error(`Vapi socket closed (${code}) before it opened`)));
    }), this.cfg.vapiConnectMs, 'Vapi socket');
    ws.on('error', (err) => this.log('warn', 'vapi socket error', { error: err.message }));
    ws.on('close', (code) => this.end('ended', this.accepted ? 'assistant_ended' : `vapi_closed_${code}`));
    this.log('info', 'vapi socket open');
  }

  // JSON from Vapi. The transport documents no inbound types; we act on interruptions and log the rest.
  #control(text) {
    let m;
    try { m = JSON.parse(text); } catch { return; }
    const type = m?.type || 'unknown';
    this.stats.controlTypes[type] = (this.stats.controlTypes[type] || 0) + 1;
    if (this.stats.controlTypes[type] === 1) this.log('debug', 'vapi control message', { type });
    if (type === 'user-interrupted' || type === 'clear') {
      // the caller talked over the assistant: drop what is queued so it stops at once
      const ms = this.playout.bufferedMs;
      this.playout.clear();
      if (ms) this.log('debug', 'barge-in: cleared playout', { ms: Math.round(ms) });
    } else if (type === 'hangup' || type === 'end-call') {
      this.end('ended', 'assistant_ended');
    }
  }

  // decoded caller audio (libwebrtc: 10 ms of 16-bit PCM, usually 48 kHz) → 16 kHz → Vapi
  #fromCaller(d) {
    if (!this.accepted || this.ended || this.ws?.readyState !== 1) return;
    this.stats.callerFrames++;
    const mono = downmix(d.samples, d.channelCount || 1);
    if (!this.resampler || this.resampler.from !== d.sampleRate) this.resampler = new Resampler(d.sampleRate, this.cfg.sampleRate);
    const out = this.resampler.push(mono);
    this.pending.push(out);
    this.pendingLen += out.length;
    if (this.pendingLen >= (this.cfg.sampleRate * SEND_EVERY_MS) / 1000) {
      const chunk = new Int16Array(this.pendingLen);
      let o = 0;
      for (const p of this.pending) { chunk.set(p, o); o += p.length; }
      this.pending = [];
      this.pendingLen = 0;
      const bytes = toBytes(chunk);
      this.stats.toVapiBytes += bytes.length;
      this.ws.send(bytes);
    }
  }

  // one 10 ms frame of assistant audio (or silence) → WhatsApp; libwebrtc resamples and Opus-encodes it
  #toCaller(samples) {
    if (this.ended || !this.source) return;
    this.source.onData({ samples, sampleRate: this.cfg.sampleRate, bitsPerSample: 16, channelCount: 1, numberOfFrames: samples.length });
  }

  /**
   * Ends the call once, whoever ends it.
   * @param remote true when Meta already ended it (terminate webhook): no call-control request then
   */
  async end(finalState, reason, { remote = false } = {}) {
    if (this.ended) return;
    this.ended = true;
    this.state = finalState;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.playout.stop();
    const duration = this.answeredAt ? Math.round((Date.now() - this.answeredAt) / 1000) : 0;
    this.log('info', 'call ended', { state: finalState, reason, duration_s: duration, ...this.#statsSummary() });

    if (!remote) {
      try {
        // reject a call we never accepted, terminate one we did (Meta bills until terminate)
        await (this.accepted ? this.deps.meta.terminate(this.id) : this.deps.meta.reject(this.id));
      } catch (err) {
        this.log('warn', 'meta end request failed', { error: err.message });
      }
    }
    const ws = this.ws;
    this.ws = null;
    if (ws) {
      try {
        if (ws.readyState === 1) { ws.send(JSON.stringify({ type: 'end-call' })); ws.close(1000); }
        else ws.terminate?.();
      } catch { /* already gone */ }
    }
    try { this.sink?.stop(); } catch { /* ignore */ }
    try { this.track?.stop(); } catch { /* ignore */ }
    try { this.pc?.close(); } catch { /* ignore */ }
    this.sink = this.track = this.source = this.pc = null;
    this.#report(finalState, { reason, duration_s: duration });
    this.emit('end', { state: finalState, reason });
  }

  #statsSummary() {
    return { to_vapi_kb: Math.round(this.stats.toVapiBytes / 1024), from_vapi_kb: Math.round(this.stats.fromVapiBytes / 1024),
             caller_frames: this.stats.callerFrames, dropped_samples: this.playout.dropped };
  }

  info() {
    return { meta_call_id: this.id, vapi_call_id: this.vapiCallId, state: this.state, from: mask(this.from), name: this.name,
             since: new Date(this.createdAt).toISOString(), media: this.pc?.connectionState || null,
             buffered_ms: Math.round(this.playout.bufferedMs), ...this.#statsSummary(), control: this.stats.controlTypes };
  }
}

const mask = (n) => (n ? `…${String(n).slice(-4)}` : '');

module.exports = { CallSession, waitIceGathering, mask };
