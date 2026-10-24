import { describe, isAgent, snapshot } from '@/lib/agent';

// POST /api/agent/context { wa_id } — who is calling, for the voice agent. voice-bridge asks when a WhatsApp call
// starts and hands the text to Vapi as the variable tori_caller (shown in the assistant's prompt, scripts/vapi-mcp.sh).
// Same key as the MCP server (x-tori-mcp-key).
export async function POST(req: Request) {
  if (!isAgent(req)) return Response.json({ error: 'key' }, { status: 401 });
  const b = await req.json().catch(() => ({}));
  const wa = String(b?.wa_id || '').replace(/\D/g, '');
  if (!/^\d{8,15}$/.test(wa)) return Response.json({ error: 'wa_id' }, { status: 400 });
  const x = await snapshot(wa);
  return Response.json({ name: x.name, text: describe(x, wa) });
}
