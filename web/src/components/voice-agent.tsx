'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type Vapi from '@vapi-ai/web';
import { AlertTriangle, ExternalLink, Loader2, Mic, MicOff, Phone, PhoneOff } from 'lucide-react';
import { btn } from './ui';
import { addTranscript, describeVapiError, isFatalVapiError, isTranscript, type Line } from '@/lib/voice';

type Status = 'idle' | 'connecting' | 'connected' | 'ending' | 'error';

const STATUS: Record<Status, { label: string; dot: string }> = {
  idle: { label: 'Disconnected', dot: 'bg-border-strong' },
  connecting: { label: 'Connecting…', dot: 'bg-sig-mustard animate-pulse' },
  connected: { label: 'Connected', dot: 'bg-success-border live-dot' },
  ending: { label: 'Ending…', dot: 'bg-sig-mustard' },
  error: { label: 'Error', dot: 'bg-sig-coral' },
};

const WEB_CALLER = 'A visitor on the Tori website, not identified. Search open games with them; for anything personal '
  + '(their requests, profile, wallet, finding a partner or cab buddy) ask them to call or message Tori on WhatsApp.';
const START_TIMEOUT_MS = 25_000;
const BARS = 28;
// fixed per-bar weights so the waveform has a shape instead of moving as one block
const WEIGHTS = Array.from({ length: BARS }, (_, i) => 0.35 + 0.65 * Math.abs(Math.sin(i * 1.7) * Math.cos(i * 0.45)));

// Ask for the microphone before starting, so a denial gets a clear message instead of a failed call.
async function checkMicrophone(): Promise<string | null> {
  if (!window.isSecureContext) return 'The microphone only works on HTTPS pages (or localhost).';
  if (!navigator.mediaDevices?.getUserMedia) return 'This browser can’t use a microphone.';
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((t) => t.stop());
    return null;
  } catch (e) {
    const name = (e as DOMException)?.name;
    if (name === 'NotAllowedError' || name === 'SecurityError')
      return 'Microphone access was blocked. Allow it from the address bar (the lock or mic icon), then try again.';
    if (name === 'NotFoundError' || name === 'OverconstrainedError') return 'No microphone was found. Plug one in and try again.';
    if (name === 'NotReadableError') return 'Another app is using the microphone. Close it and try again.';
    return 'Could not open the microphone.';
  }
}

export function VoiceAgent({ publicKey, assistantId }: { publicKey: string; assistantId: string }) {
  const [status, setStatus] = useState<Status>('idle');
  const [error, setError] = useState<string | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [assistantSpeaking, setAssistantSpeaking] = useState(false);
  const [userSpeaking, setUserSpeaking] = useState(false);
  const [level, setLevel] = useState(0);
  const [muted, setMuted] = useState(false);
  const [seconds, setSeconds] = useState(0);

  const vapiRef = useRef<Vapi | null>(null);
  const busyRef = useRef(false); // a start or stop is in flight: ignore repeated clicks
  const idRef = useRef(0);
  const startTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const userLevel = useRef(0);
  const scrollRef = useRef<HTMLDivElement>(null);

  const clearStartTimer = () => { if (startTimer.current) clearTimeout(startTimer.current); startTimer.current = null; };

  const resetCallState = useCallback(() => {
    clearStartTimer();
    setAssistantSpeaking(false);
    setUserSpeaking(false);
    setLevel(0);
    setMuted(false);
    busyRef.current = false;
  }, []);

  const fail = useCallback((message: string) => {
    setError(message);
    setStatus('error');
    resetCallState();
    vapiRef.current?.stop().catch(() => {});
  }, [resetCallState]);

  // One SDK instance per page, created on first use (the SDK needs `window`, so not during SSR).
  const getVapi = useCallback(async (): Promise<Vapi> => {
    if (vapiRef.current) return vapiRef.current;
    const { default: VapiClient } = await import('@vapi-ai/web');
    const vapi = new VapiClient(publicKey);
    vapi.on('call-start', () => {
      clearStartTimer();
      busyRef.current = false;
      setStatus('connected');
    });
    vapi.on('call-end', () => {
      resetCallState();
      setStatus((s) => (s === 'error' ? s : 'idle'));
    });
    vapi.on('speech-start', () => setAssistantSpeaking(true));
    vapi.on('speech-end', () => setAssistantSpeaking(false));
    vapi.on('volume-level', (v: number) => setLevel(Math.max(v, userLevel.current)));
    vapi.on('local-volume-level', (v: number) => { userLevel.current = v; });
    vapi.on('message', (m: { type?: string; role?: string; status?: string; endedReason?: string }) => {
      if (isTranscript(m)) {
        setLines((ls) => addTranscript(ls, m, ++idRef.current));
      } else if (m?.type === 'speech-update' && m.role === 'user') {
        setUserSpeaking(m.status === 'started');
      }
    });
    vapi.on('error', (e: unknown) => {
      console.error('[vapi]', e);
      if (isFatalVapiError(e)) fail(describeVapiError(e));
    });
    vapiRef.current = vapi;
    return vapi;
  }, [publicKey, fail, resetCallState]);

  async function start() {
    if (busyRef.current || status === 'connecting' || status === 'connected') return;
    if (!publicKey) return fail('This page has no Vapi public key yet (NEXT_PUBLIC_VAPI_PUBLIC_KEY).');
    busyRef.current = true;
    setError(null);
    setLines([]);
    setSeconds(0);
    setStatus('connecting');
    const micError = await checkMicrophone();
    if (micError) return fail(micError);
    try {
      const vapi = await getVapi();
      startTimer.current = setTimeout(() => fail('The call took too long to connect. Please try again.'), START_TIMEOUT_MS);
      // the website doesn't know who is talking: the prompt's "who is calling" says so (scripts/vapi-mcp.sh)
      const call = await vapi.start(assistantId, { variableValues: { channel: 'web', tori_caller: WEB_CALLER } });
      // null = the SDK failed and already emitted `error`; keep a message in case it did not
      if (!call) fail(describeVapiError(null));
    } catch (e) {
      fail(describeVapiError(e));
    }
  }

  async function stop() {
    if (status !== 'connected' && status !== 'connecting') return;
    busyRef.current = true;
    setStatus('ending');
    try {
      await vapiRef.current?.stop();
    } finally {
      // `call-end` normally does this; don't stay on "Ending…" if it never comes
      setTimeout(() => setStatus((s) => (s === 'ending' ? 'idle' : s)), 3000);
      resetCallState();
    }
  }

  function toggleMute() {
    const vapi = vapiRef.current;
    if (!vapi || status !== 'connected') return;
    vapi.setMuted(!muted);
    setMuted(!muted);
  }

  // call timer
  useEffect(() => {
    if (status !== 'connected') return;
    const t = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, [status]);

  // keep the newest line in view
  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
  }, [lines]);

  // leaving the page ends the call and frees the microphone
  useEffect(() => () => {
    clearStartTimer();
    const vapi = vapiRef.current;
    vapiRef.current = null;
    vapi?.removeAllListeners();
    vapi?.stop().catch(() => {});
  }, []);

  const live = status === 'connected';
  const s = STATUS[status];
  const activity = !live ? null : assistantSpeaking ? 'Harsh AI is speaking' : userSpeaking ? 'Listening to you…' : muted ? 'Muted' : 'Listening';

  return (
    <div className="flex flex-1 flex-col gap-6">
      <header className="flex flex-col gap-2">
        <span className="inline-flex w-fit items-center gap-2 rounded-full border border-hairline bg-canvas px-3 py-1 text-caption text-muted">
          <span className={`size-2 rounded-full ${s.dot}`} aria-hidden />
          <span aria-live="polite">{s.label}</span>
          {live && <span className="tabular-nums">· {Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}</span>}
        </span>
        <h1 className="font-display text-display-md font-normal sm:text-display-lg">Harsh AI</h1>
        <p className="max-w-xl text-label text-muted">
          A voice assistant that answers questions about Harsh Kharwar: his education at IIIT Bhagalpur, his work, projects and skills.
          Press start and just talk.
        </p>
      </header>

      <section className="flex flex-col items-center gap-6 rounded-lg border border-hairline bg-canvas px-4 py-8 sm:px-8">
        <div className="flex h-24 w-full max-w-md items-center justify-center gap-[3px]" aria-hidden>
          {WEIGHTS.map((w, i) => (
            <span
              key={i}
              className={`w-1.5 rounded-full transition-[height] duration-100 ease-out ${assistantSpeaking ? 'bg-info-border' : live ? 'bg-primary' : 'bg-surface-strong'}`}
              style={{ height: `${Math.max(6, Math.min(96, (live ? 8 + level * 160 : 6) * w))}px` }}
            />
          ))}
        </div>
        <p className="h-5 text-body text-muted" aria-live="polite">
          {activity ?? (status === 'connecting' ? 'Asking for the microphone and connecting…' : 'Not in a call')}
        </p>

        <div className="flex flex-wrap items-center justify-center gap-3">
          {live || status === 'ending' ? (
            <>
              <button type="button" onClick={toggleMute} disabled={!live} className={btn('secondary')} aria-pressed={muted}>
                {muted ? <MicOff className="size-4" aria-hidden /> : <Mic className="size-4" aria-hidden />}
                {muted ? 'Unmute' : 'Mute'}
              </button>
              <button type="button" onClick={stop} disabled={!live} className={btn('primary', 'md', 'bg-sig-coral hover:bg-sig-coral active:bg-sig-coral')}>
                {status === 'ending' ? <Loader2 className="size-4 animate-spin" aria-hidden /> : <PhoneOff className="size-4" aria-hidden />}
                End conversation
              </button>
            </>
          ) : (
            <button type="button" onClick={start} disabled={status === 'connecting'} className={btn('primary')}>
              {status === 'connecting' ? <Loader2 className="size-4 animate-spin" aria-hidden /> : <Phone className="size-4" aria-hidden />}
              {status === 'connecting' ? 'Connecting…' : status === 'error' ? 'Try again' : 'Start conversation'}
            </button>
          )}
        </div>

        {error && (
          <p role="alert" className="flex max-w-md items-start gap-2 rounded-sm border border-sig-peach bg-sig-cream px-4 py-3 text-body text-ink">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-sig-coral" aria-hidden />
            {error}
          </p>
        )}
      </section>

      <section className="flex min-h-64 flex-1 flex-col rounded-lg border border-hairline bg-canvas">
        <h2 className="border-b border-hairline px-4 py-3 text-label font-medium sm:px-6">Transcript</h2>
        <div ref={scrollRef} className="flex max-h-[50dvh] flex-1 flex-col gap-3 overflow-y-auto px-4 py-4 sm:px-6" aria-live="polite">
          {lines.length === 0 ? (
            <p className="m-auto text-center text-body text-muted">What you and Harsh AI say appears here.</p>
          ) : (
            lines.map((l) => (
              <div key={l.id} className={`flex ${l.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                <p className={`max-w-[85%] rounded-lg px-4 py-2.5 text-body ${l.role === 'user' ? 'bg-primary text-on-primary' : 'bg-surface-soft text-ink'} ${l.final ? '' : 'opacity-70'}`}>
                  <span className="sr-only">{l.role === 'user' ? 'You: ' : 'Harsh AI: '}</span>
                  {l.text}
                </p>
              </div>
            ))
          )}
        </div>
      </section>

      <footer className="flex items-center justify-center gap-2 text-caption text-muted">
        <ExternalLink className="size-4" aria-hidden />
        <a className="text-link hover:text-link-active" href="https://github.com/Harsh-DevOps117" target="_blank" rel="noreferrer">github.com/Harsh-DevOps117</a>
      </footer>
    </div>
  );
}
