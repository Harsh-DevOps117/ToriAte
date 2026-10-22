// npm test   (Node 22.18+ runs the .ts import directly)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addTranscript, describeVapiError, isFatalVapiError, isTranscript } from '../src/lib/voice.ts';

const t = (role, transcriptType, transcript) => ({ type: 'transcript', role, transcriptType, transcript });

test('partials replace the open line, a final closes it', () => {
  let lines = [];
  lines = addTranscript(lines, t('user', 'partial', 'who'), 1);
  lines = addTranscript(lines, t('user', 'partial', 'who is harsh'), 2);
  assert.deepEqual(lines, [{ id: 1, role: 'user', text: 'who is harsh', final: false }]);
  lines = addTranscript(lines, t('user', 'final', 'Who is Harsh?'), 3);
  assert.deepEqual(lines, [{ id: 1, role: 'user', text: 'Who is Harsh?', final: true }]);
  lines = addTranscript(lines, t('user', 'partial', 'and'), 4);
  assert.equal(lines.length, 2);
  assert.equal(lines[1].id, 4);
});

test('speakers keep separate lines even when they overlap', () => {
  let lines = [];
  lines = addTranscript(lines, t('assistant', 'partial', 'Harsh studied'), 1);
  lines = addTranscript(lines, t('user', 'partial', 'wait'), 2);          // barge-in
  lines = addTranscript(lines, t('assistant', 'final', 'Harsh studied at IIIT Bhagalpur.'), 3);
  assert.deepEqual(lines.map((l) => [l.role, l.text, l.final]), [
    ['assistant', 'Harsh studied at IIIT Bhagalpur.', true],
    ['user', 'wait', false],
  ]);
});

test('empty transcripts are ignored', () => {
  assert.deepEqual(addTranscript([], t('user', 'final', '  '), 1), []);
});

test('isTranscript accepts both transcript message types and nothing else', () => {
  assert.ok(isTranscript(t('user', 'final', 'hi')));
  assert.ok(isTranscript({ ...t('assistant', 'final', 'hi'), type: "transcript[transcriptType='final']" }));
  assert.ok(!isTranscript({ type: 'speech-update', role: 'user', status: 'started' }));
  assert.ok(!isTranscript({ type: 'transcript', role: 'system', transcript: 'x' }));
  assert.ok(!isTranscript(null));
});

test('SDK errors become readable messages', () => {
  assert.match(describeVapiError({ type: 'start-method-error', error: { message: 'HTTP 401 Unauthorized' } }), /refused this site’s key/);
  assert.match(describeVapiError({ type: 'daily-call-join-error', error: { errorMsg: 'NotAllowedError: Permission denied' } }), /Microphone/);
  assert.match(describeVapiError(new Error('Failed to fetch')), /Could not reach/);
  assert.match(describeVapiError(undefined), /Something went wrong/);
});

test('only setup-of-extras errors are non-fatal', () => {
  assert.equal(isFatalVapiError({ type: 'audio-observer-setup-error' }), false);
  assert.equal(isFatalVapiError({ type: 'daily-error' }), true);
  assert.equal(isFatalVapiError('boom'), true);
});
