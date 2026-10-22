'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Resampler, PcmDecoder, PlayoutQueue, downmix, toBytes } = require('../src/audio');
const { tone, power } = require('./helpers');

test('48 kHz → 16 kHz keeps a 1 kHz tone and its level', () => {
  const r = new Resampler(48000, 16000);
  const input = tone(1000, 48000, 0.5, 10000);
  const out = r.push(input);
  assert.equal(out.length, 8000);
  const rms = Math.sqrt(out.slice(1000).reduce((s, v) => s + v * v, 0) / (out.length - 1000));
  assert.ok(Math.abs(rms - 10000 / Math.SQRT2) < 300, `rms ${rms}`);
  assert.ok(power(out.slice(1000), 1000, 16000) > 100 * power(out.slice(1000), 3000, 16000));
});

test('48 kHz → 16 kHz filters out what would alias (a 12 kHz tone)', () => {
  const r = new Resampler(48000, 16000);
  const out = r.push(tone(12000, 48000, 0.5, 10000));
  const rms = Math.sqrt(out.slice(500).reduce((s, v) => s + v * v, 0) / (out.length - 500));
  assert.ok(rms < 100, `12 kHz leaked through at rms ${rms}`); // unfiltered it would fold to 4 kHz at ~7000
});

test('streaming in 10 ms frames gives the same samples as one block', () => {
  const input = tone(700, 48000, 0.3, 8000);
  const whole = new Resampler(48000, 16000).push(input);
  const r = new Resampler(48000, 16000);
  const parts = [];
  for (let i = 0; i < input.length; i += 480) parts.push(...r.push(input.subarray(i, i + 480)));
  assert.deepEqual(Int16Array.from(parts), whole);
});

test('non-integer ratios (44.1 kHz) resample to the right length, continuously', () => {
  const r = new Resampler(44100, 16000);
  let n = 0;
  for (let i = 0; i < 100; i++) n += r.push(tone(500, 44100, 0.01, 5000)).length;
  assert.ok(Math.abs(n - 16000) <= 2, `got ${n} samples for 1 s`);
});

test('downmix averages interleaved channels', () => {
  assert.deepEqual(downmix(Int16Array.from([100, 300, -50, 50]), 2), Int16Array.from([200, 0]));
});

test('PCM decoder joins a sample split across WebSocket messages', () => {
  const d = new PcmDecoder();
  const bytes = toBytes(Int16Array.from([1234, -2, 32767]));
  const a = d.push(bytes.subarray(0, 3));
  const b = d.push(bytes.subarray(3));
  assert.deepEqual([...a, ...b], [1234, -2, 32767]);
});

test('playout hands out 10 ms frames in real time, silence when empty, and clears on barge-in', () => {
  let now = 0;
  const frames = [];
  const q = new PlayoutQueue({ sampleRate: 16000, onFrame: (s, speech) => frames.push({ n: s.length, speech, first: s[0] }), now: () => now });
  q.push(Int16Array.from({ length: 400 }, () => 7)); // 25 ms of speech arrives at once
  q.t0 = 0; q.sent = 0;                                   // start() without the real timer
  now = 30; q.tick();
  assert.deepEqual(frames.map((f) => f.speech), [true, true, true]);
  assert.ok(frames.every((f) => f.n === 160));
  now = 50; q.tick();
  assert.deepEqual(frames.slice(3).map((f) => f.speech), [false, false], 'silence keeps RTP going');
  q.push(new Int16Array(16000));
  assert.equal(Math.round(q.bufferedMs), 1000);
  q.clear();
  assert.equal(q.bufferedMs, 0);
});

test('playout caps its buffer', () => {
  const q = new PlayoutQueue({ sampleRate: 16000, maxSeconds: 1, onFrame: () => {} });
  q.push(new Int16Array(12000));
  q.push(new Int16Array(12000));
  assert.equal(q.queued, 12000);
  assert.equal(q.dropped, 12000);
});
