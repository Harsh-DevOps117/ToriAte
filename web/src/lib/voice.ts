// Helpers for the Harsh AI voice page (components/voice-agent.tsx), kept free of React and the SDK
// so tests/voice.test.ts can run them under plain Node.

// Errors the SDK reports but recovers from: the call goes on without that feature.
const NON_FATAL = new Set(['video-recording-setup-error', 'audio-observer-setup-error', 'audio-processing-setup-error']);

export function isFatalVapiError(e: unknown): boolean {
  const type = (e as { type?: string } | null)?.type;
  return !type || !NON_FATAL.has(type);
}

// The SDK's `error` event: { type, stage, error: { message, errorMsg, ... } }, or a bare Error/string.
export function describeVapiError(e: unknown): string {
  const parts: string[] = [];
  const walk = (v: unknown, depth: number) => {
    if (v == null || depth > 3) return;
    if (typeof v === 'string') { parts.push(v); return; }
    if (typeof v !== 'object') return;
    const o = v as Record<string, unknown>;
    for (const k of ['message', 'errorMsg', 'errorDetail', 'statusText']) if (typeof o[k] === 'string') parts.push(o[k] as string);
    for (const k of ['error', 'cause', 'details']) walk(o[k], depth + 1);
  };
  walk(e, 0);
  const raw = parts.join(' ').toLowerCase();
  if (/401|403|unauthori[sz]ed|invalid key|forbidden/.test(raw))
    return 'The voice service refused this site’s key. Check NEXT_PUBLIC_VAPI_PUBLIC_KEY and its allowed origins in the Vapi dashboard.';
  if (/assistant.*(not found|does not exist)|404/.test(raw))
    return 'The Harsh AI assistant could not be found. Check VAPI_ASSISTANT_ID.';
  if (/permission|notallowed|denied/.test(raw))
    return 'Microphone access was blocked. Allow the microphone for this site and try again.';
  if (/network|failed to fetch|timeout|ice|websocket|meeting/.test(raw))
    return 'Could not reach the voice service. Check your connection and try again.';
  return 'Something went wrong with the call. Please try again.';
}

// Live transcript. Vapi sends `transcript` messages per speaker: many
// "partial" ones while someone talks, then one "final". A partial replaces the speaker's open line;
// a final closes it, so the next partial starts a new line.

export type Role = 'user' | 'assistant';
export type Line = { id: number; role: Role; text: string; final: boolean };

export type TranscriptMessage = {
  type: string;
  role?: string;
  transcriptType?: string;
  transcript?: string;
};

export function isTranscript(m: unknown): m is Required<TranscriptMessage> {
  const t = m as TranscriptMessage | null;
  return !!t && (t.type === 'transcript' || t.type?.startsWith('transcript['))
    && (t.role === 'user' || t.role === 'assistant') && typeof t.transcript === 'string';
}

export function addTranscript(lines: Line[], m: Required<TranscriptMessage>, nextId: number): Line[] {
  const role = m.role as Role;
  const final = m.transcriptType === 'final';
  const text = m.transcript.trim();
  if (!text) return lines;
  // the speaker's open (partial) line, if there is one; the other speaker may have spoken since
  let open = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].role === role) { if (!lines[i].final) open = i; break; }
  }
  if (open === -1) return [...lines, { id: nextId, role, text, final }];
  const out = lines.slice();
  out[open] = { ...out[open], text, final };
  return out;
}
