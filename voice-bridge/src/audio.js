'use strict';
// Audio between WhatsApp (WebRTC: Opus, decoded by libwebrtc into 16-bit PCM, usually 48 kHz) and Vapi
// (raw pcm_s16le, 16 kHz mono). Opus decode/encode happens inside @roamhq/wrtc; this file does the rest:
// downmix, resampling with a low-pass filter, byte framing, and a real-time playout queue.

// Windowed-sinc low-pass FIR, cutoff `fc` as a fraction of the input rate (0.5 = Nyquist).
function lowpassTaps(n, fc) {
  const taps = new Float64Array(n);
  const mid = (n - 1) / 2;
  let sum = 0;
  for (let i = 0; i < n; i++) {
    const x = i - mid;
    const sinc = x === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * x) / (Math.PI * x);
    const blackman = 0.42 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1)) + 0.08 * Math.cos((4 * Math.PI * i) / (n - 1));
    taps[i] = sinc * blackman;
    sum += taps[i];
  }
  for (let i = 0; i < n; i++) taps[i] /= sum; // unity gain at DC
  return taps;
}

const clamp16 = (v) => (v > 32767 ? 32767 : v < -32768 ? -32768 : Math.round(v));

// Streaming resampler from `fromRate` to `toRate` (mono Int16). Downsampling runs a low-pass FIR first so
// nothing above the new Nyquist folds back as noise; integer factors (48k → 16k) only evaluate the filter at
// the samples they keep. Other ratios interpolate linearly. State carries across calls, so 10 ms frames
// join without clicks.
class Resampler {
  constructor(fromRate, toRate) {
    this.from = fromRate;
    this.to = toRate;
    this.ratio = fromRate / toRate;
    this.taps = this.ratio > 1 ? lowpassTaps(63, 0.45 / this.ratio) : null;
    this.hist = new Float64Array(this.taps ? this.taps.length - 1 : 0);
    this.pos = 0;   // where the next output sample falls, in input samples from the start of the next chunk
    this.prev = 0;  // last (filtered) input sample, for interpolating across chunk edges
  }

  push(input) {
    if (this.from === this.to) return input;
    const n = this.taps ? this.taps.length : 1;
    const buf = new Float64Array(this.hist.length + input.length);
    buf.set(this.hist, 0);
    for (let i = 0; i < input.length; i++) buf[this.hist.length + i] = input[i];
    this.hist = buf.slice(buf.length - this.hist.length);
    // filtered input sample i (0 ≤ i < input.length)
    const at = !this.taps ? (i) => buf[i] : (i) => {
      let acc = 0;
      for (let k = 0; k < n; k++) acc += this.taps[k] * buf[i + k];
      return acc;
    };

    const out = [];
    if (Number.isInteger(this.ratio)) {
      let i = this.pos;
      for (; i < input.length; i += this.ratio) out.push(clamp16(at(i)));
      this.pos = i - input.length;
      return Int16Array.from(out);
    }
    // linear: position p is measured from the previous chunk's last sample (p = 0) to this chunk's (p = len)
    const y = (j) => (j === 0 ? this.prev : at(j - 1));
    let p = this.pos;
    for (; p < input.length; p += this.ratio) {
      const j = Math.floor(p);
      const a = y(j);
      out.push(clamp16(a + (y(j + 1) - a) * (p - j)));
    }
    this.pos = p - input.length;
    this.prev = at(input.length - 1);
    return Int16Array.from(out);
  }
}

// interleaved multi-channel → mono
function downmix(samples, channels) {
  if (channels === 1) return samples;
  const out = new Int16Array(Math.floor(samples.length / channels));
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    for (let c = 0; c < channels; c++) s += samples[i * channels + c];
    out[i] = s / channels;
  }
  return out;
}

const toBytes = (samples) => Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength);

// Turns arbitrary binary WebSocket messages into Int16 samples, keeping a dangling odd byte for the next one.
class PcmDecoder {
  constructor() { this.rest = null; }
  push(buf) {
    let b = this.rest ? Buffer.concat([this.rest, buf]) : buf;
    this.rest = null;
    if (b.length % 2) { this.rest = b.subarray(b.length - 1); b = b.subarray(0, b.length - 1); }
    const copy = new Int16Array(b.length / 2);
    for (let i = 0; i < copy.length; i++) copy[i] = b.readInt16LE(i * 2);
    return copy;
  }
}

// Vapi sends speech in bursts, usually faster than real time. The queue holds it and hands out exactly one
// 10 ms frame per tick, on a drift-corrected clock, with silence when there is nothing to say (so RTP keeps
// flowing). clear() drops what is queued: used when the caller interrupts.
class PlayoutQueue {
  constructor({ sampleRate, frameMs = 10, maxSeconds = 60, onFrame, now = () => performance.now() }) {
    this.frame = (sampleRate * frameMs) / 1000;
    this.frameMs = frameMs;
    this.max = sampleRate * maxSeconds;
    this.onFrame = onFrame;
    this.now = now;
    this.chunks = [];
    this.offset = 0;      // read offset into chunks[0]
    this.queued = 0;
    this.timer = null;
    this.dropped = 0;
  }

  get bufferedMs() { return (this.queued / this.frame) * this.frameMs; }

  push(samples) {
    if (!samples.length) return;
    if (this.queued + samples.length > this.max) { this.dropped += samples.length; return; }
    this.chunks.push(samples);
    this.queued += samples.length;
  }

  clear() {
    this.chunks = [];
    this.offset = 0;
    this.queued = 0;
  }

  // the next frame: queued speech, padded with silence when it runs out
  take() {
    const out = new Int16Array(this.frame);
    let filled = 0;
    while (filled < this.frame && this.chunks.length) {
      const c = this.chunks[0];
      const n = Math.min(this.frame - filled, c.length - this.offset);
      out.set(c.subarray(this.offset, this.offset + n), filled);
      filled += n;
      this.offset += n;
      if (this.offset === c.length) { this.chunks.shift(); this.offset = 0; }
    }
    this.queued -= filled;
    return { samples: out, speech: filled > 0 };
  }

  start() {
    if (this.timer) return;
    this.t0 = this.now();
    this.sent = 0;
    this.timer = setInterval(() => this.tick(), this.frameMs / 2);
  }

  tick() {
    const due = Math.floor((this.now() - this.t0) / this.frameMs) - this.sent;
    // after a stall (GC, busy event loop) don't burst more than 100 ms; just resync the clock
    if (due > 10) { this.t0 = this.now() - this.frameMs; this.sent = 0; }
    for (let i = 0; i < Math.min(due, 10); i++) {
      this.sent++;
      const f = this.take();
      this.onFrame(f.samples, f.speech);
    }
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.clear();
  }
}

module.exports = { Resampler, PcmDecoder, PlayoutQueue, downmix, toBytes, lowpassTaps };
