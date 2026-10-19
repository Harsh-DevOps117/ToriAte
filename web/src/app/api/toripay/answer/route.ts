import { rpc } from '@/lib/db';
import { contactsConfigured, createFundAccount, isBot } from '@/lib/razorpayx';

type Draft = { kind: string; step?: string };
type Check = { ok?: boolean; kind?: string; handle: string; display_name: string; holder: string; ifsc: string };
type Bank = { BANK?: string; BRANCH?: string };

const IFSC_API = (process.env.IFSC_API_URL || 'https://ifsc.razorpay.com').replace(/\/+$/, '');
const r = (x: unknown) => Response.json(x);
const call = async <T,>(sql: string, params: unknown[]) => (await rpc<{ r: T }>(sql, params))!.r;

// Razorpay's public IFSC directory: the bank and branch, or false if there is no such code.
// null = the directory didn't answer; the IFSC is then taken as typed (its format is still checked).
async function lookupIfsc(ifsc: string): Promise<Bank | false | null> {
  try {
    const res = await fetch(`${IFSC_API}/${ifsc}`, { cache: 'no-store', signal: AbortSignal.timeout(5000) });
    if (res.status === 404) return false;
    return res.ok ? ((await res.json()) as Bank) : null;
  } catch {
    return null;
  }
}

// POST /api/toripay/answer { wa_id, text } — the bot (x-tori-key) forwards each answer while someone adds a
// payee on WhatsApp (db: toripay_draft_*). The second account number goes to RazorpayX from here and is
// not stored or logged anywhere; the reply is what the bot should say (kind add_step / added / confirm …).
export async function POST(req: Request) {
  if (!isBot(req)) return Response.json({ error: 'key' }, { status: 401 });
  const b = await req.json().catch(() => ({}));
  const wa = String(b?.wa_id || '').replace(/\D/g, '');
  const text = String(b?.text || '').trim().slice(0, 200);
  if (!/^\d{8,15}$/.test(wa)) return Response.json({ error: 'wa_id' }, { status: 400 });

  const d = await call<Draft | null>('SELECT public.toripay_draft_get($1) AS r', [wa]);
  if (!d) return r({ kind: 'add_gone' });
  if (/^(cancel|stop|exit|quit|no|nahi|band karo)[.!]*$/i.test(text)) {
    return r(await call('SELECT public.toripay_draft_cancel($1) AS r', [wa]));
  }

  if (d.step === 'ifsc') {
    const ifsc = text.toUpperCase().replace(/[\s-]/g, '');
    if (!/^[A-Z]{4}0[A-Z0-9]{6}$/.test(ifsc)) return r({ ...d, error: 'ifsc' });
    const bank = await lookupIfsc(ifsc);
    if (bank === false) return r({ ...d, error: 'ifsc_unknown' });
    return r(await call('SELECT public.toripay_draft_answer($1, $2::jsonb) AS r',
                        [wa, JSON.stringify({ ifsc, bank: bank?.BANK || '', branch: bank?.BRANCH || '' })]));
  }

  if (d.step === 'account_confirm') {
    const account = text.replace(/[\s-]/g, '');
    const c = await call<Check>('SELECT public.toripay_draft_check($1, $2) AS r', [wa, account]);
    if (!c.ok) return r(c);
    if (!contactsConfigured()) {
      await call('SELECT public.toripay_draft_cancel($1) AS r', [wa]);
      return r({ kind: 'add_failed', reason: 'not_configured' });
    }
    let fa: { contact_id: string; fund_account_id: string };
    try {
      fa = await createFundAccount({ handle: c.handle, name: c.display_name, holder: c.holder, ifsc: c.ifsc, account });
    } catch (e) {
      const detail = (e as Error).message.replace(/^razorpayx POST \S+: \d+\s*/, '');
      console.error('toripay fund account', wa.slice(-4), detail);
      return r(await call('SELECT public.toripay_draft_back($1, $2, $3, $4) AS r', [wa, 'account', 'bank', detail]));
    }
    return r(await call('SELECT public.toripay_draft_finish($1, $2, $3) AS r', [wa, fa.contact_id, fa.fund_account_id]));
  }

  return r(await call('SELECT public.toripay_draft_answer($1, $2::jsonb) AS r', [wa, JSON.stringify({ text })]));
}
