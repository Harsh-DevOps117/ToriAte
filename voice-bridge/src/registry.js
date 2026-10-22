'use strict';
// Which calls the bridge is handling. Meta retries webhooks, and n8n may forward the same connect twice:
// a call ID is handled once, and stays remembered for a while after it ends so a late retry can't start
// a second Vapi session for it.

class Registry {
  constructor({ maxCalls = 5, rememberMs = 15 * 60 * 1000, now = Date.now } = {}) {
    this.maxCalls = maxCalls;
    this.rememberMs = rememberMs;
    this.now = now;
    this.active = new Map();  // meta call id → CallSession
    this.done = new Map();    // meta call id → when it ended (or was turned away)
  }

  // 'ok' | 'duplicate' | 'busy'
  admit(id) {
    this.prune();
    if (this.active.has(id) || this.done.has(id)) return 'duplicate';
    if (this.active.size >= this.maxCalls) return 'busy';
    return 'ok';
  }

  add(session) {
    this.active.set(session.id, session);
    session.once('end', () => this.finish(session.id));
  }

  finish(id) {
    this.active.delete(id);
    this.done.set(id, this.now());
  }

  get(id) { return this.active.get(id); }
  wasHandled(id) { return this.done.has(id); }
  get size() { return this.active.size; }
  list() { return [...this.active.values()]; }

  prune() {
    const cutoff = this.now() - this.rememberMs;
    for (const [id, at] of this.done) if (at < cutoff) this.done.delete(id);
  }
}

module.exports = { Registry };
