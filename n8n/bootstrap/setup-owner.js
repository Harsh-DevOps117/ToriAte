// Creates the n8n owner account from .env on first start (no-op afterwards).
const base = 'http://n8n:5678';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`${base}/healthz`)).ok) break;
    } catch {}
    await sleep(2000);
  }
  const res = await fetch(`${base}/rest/owner/setup`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: process.env.N8N_OWNER_EMAIL,
      password: process.env.N8N_OWNER_PASSWORD,
      firstName: process.env.N8N_OWNER_FIRST_NAME || 'Tori',
      lastName: process.env.N8N_OWNER_LAST_NAME || 'Ops',
    }),
  });
  const text = await res.text();
  if (res.ok) console.log('n8n owner created:', process.env.N8N_OWNER_EMAIL);
  else if (/already/i.test(text)) console.log('n8n owner already set up');
  else console.log(`owner setup skipped (HTTP ${res.status}): ${text.slice(0, 200)}`);
})();
