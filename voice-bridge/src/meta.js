'use strict';
// Meta WhatsApp Calling API: call control for user-initiated calls.
// POST /{phone-number-id}/calls with action pre_accept | accept (both carry our SDP answer) | reject | terminate.
// https://developers.facebook.com/documentation/business-messaging/whatsapp/calling/user-initiated-calls

class MetaError extends Error {
  constructor(action, status, body) {
    const e = body?.error;
    super(`Meta ${action} failed (${status}): ${e?.message || JSON.stringify(body)}`);
    this.status = status;
    this.code = e?.code;
    this.details = e?.error_data?.details;
  }
}

function metaCalls({ graphUrl, phoneNumberId, token, fetchImpl = fetch, timeoutMs = 8000 }) {
  async function post(action, callId, extra = {}) {
    const res = await fetchImpl(`${graphUrl}/${phoneNumberId}/calls`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', call_id: callId, action, ...extra }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || body.success === false) throw new MetaError(action, res.status, body);
    return body;
  }
  const answer = (sdp) => ({ session: { sdp_type: 'answer', sdp } });
  return {
    preAccept: (callId, sdp) => post('pre_accept', callId, answer(sdp)),
    // Meta requires the same SDP answer as in pre_accept
    accept: (callId, sdp, opaque) => post('accept', callId, { ...answer(sdp), ...(opaque ? { biz_opaque_callback_data: opaque.slice(0, 512) } : {}) }),
    reject: (callId) => post('reject', callId),
    terminate: (callId) => post('terminate', callId),
  };
}

// The calls in a webhook. Takes Meta's raw payload ({object, entry[].changes[]}) or an n8n WhatsApp
// Trigger item ({...change.value, field}); returns [{ id, event, from, name, phoneNumberId, sdp, ... }].
function callEvents(body) {
  const values = [];
  if (body?.object === 'whatsapp_business_account') {
    for (const entry of body.entry || []) {
      for (const ch of entry.changes || []) if (ch.field === 'calls') values.push(ch.value || {});
    }
  } else if (Array.isArray(body)) {
    return body.flatMap(callEvents);
  } else if (body?.field === 'calls' || Array.isArray(body?.calls)) {
    values.push(body);
  }
  const out = [];
  for (const v of values) {
    const contact = v.contacts?.[0];
    for (const c of v.calls || []) {
      out.push({
        id: c.id,
        event: c.event,
        direction: c.direction,
        from: c.from || c.from_user_id || contact?.wa_id || contact?.user_id || '',
        name: contact?.profile?.name || '',
        phoneNumberId: v.metadata?.phone_number_id || '',
        timestamp: c.timestamp,
        sdp: c.session?.sdp_type === 'offer' ? c.session.sdp : null,
        status: c.status,
        duration: c.duration,
        errors: v.errors || c.errors,
      });
    }
  }
  return out;
}

module.exports = { metaCalls, callEvents, MetaError };
