'use strict';
// not a test file: node --test only runs *.test.js

// Int16 sine
function tone(freq, rate, seconds, amp = 8000, phase = 0) {
  const n = Math.round(rate * seconds);
  return Int16Array.from({ length: n }, (_, i) => Math.round(amp * Math.sin(2 * Math.PI * freq * (i + phase) / rate)));
}

// Goertzel: signal power at one frequency
function power(samples, freq, rate) {
  const k = 2 * Math.cos((2 * Math.PI * freq) / rate);
  let s1 = 0, s2 = 0;
  for (const x of samples) { const s0 = x + k * s1 - s2; s2 = s1; s1 = s0; }
  return (s1 * s1 + s2 * s2 - k * s1 * s2) / samples.length;
}

module.exports = { tone, power };
