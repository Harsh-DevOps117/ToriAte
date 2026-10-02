const env = (k, fallback) => {
  const v = process.env[k] ?? fallback;
  if (v === undefined || v === '') throw new Error(`missing env ${k}`);
  return v;
};

const credentials = [
  {
    id: 'toriPostgres0001',
    name: 'Tori DB',
    type: 'postgres',
    data: {
      host: 'postgres', port: 5432, database: 'tori', user: 'tori_app',
      password: env('TORI_DB_PASSWORD'), ssl: 'disable', allowUnauthorizedCerts: false, maxConnections: 10,
    },
  },
  {
    id: 'toriInboundAuth1',
    name: 'Inbound email webhook (basic auth)',
    type: 'httpBasicAuth',
    data: { user: env('INBOUND_WEBHOOK_USER'), password: env('INBOUND_WEBHOOK_PASSWORD') },
  },
  {
    id: 'toriAdminApiKey1',
    name: 'Admin webhook key',
    type: 'httpHeaderAuth',
    data: { name: 'X-Tori-Admin-Key', value: env('ADMIN_API_KEY') },
  },
  {
    id: 'toriGroqApiKey01',
    name: 'Groq API key',
    type: 'httpHeaderAuth',
    data: { name: 'Authorization', value: `Bearer ${env('LLM_API_KEY')}` },
  },
  {
    id: 'toriWhatsAppTokn',
    name: 'WhatsApp Cloud API token',
    type: 'httpHeaderAuth',
    data: { name: 'Authorization', value: `Bearer ${env('WHATSAPP_TOKEN')}` },
  },
];

// Workflow 06 (WhatsApp bot) uses the credential IDs of the n8n it was exported from.
// The database defaults to this repo's Postgres; the rest are added only when set in .env.
const opt = (k) => process.env[k] || '';
credentials.push({
  id: 'xzG9f2LEMKhGXmqg',
  name: 'Postgres account',
  type: 'postgres',
  data: {
    host: opt('BOT_PG_HOST') || 'postgres', port: Number(opt('BOT_PG_PORT') || 5432),
    database: opt('BOT_PG_DATABASE') || 'tori', user: opt('BOT_PG_USER') || 'tori_app',
    password: opt('BOT_PG_PASSWORD') || env('TORI_DB_PASSWORD'), ssl: opt('BOT_PG_SSL') || 'disable',
    allowUnauthorizedCerts: false, maxConnections: 5,
  },
});
if (opt('BOT_WHATSAPP_TOKEN')) {
  credentials.push({
    id: 'toriWhatsAppHdr1',
    name: 'WhatsApp Cloud API',
    type: 'httpHeaderAuth',
    data: { name: 'Authorization', value: `Bearer ${opt('BOT_WHATSAPP_TOKEN')}` },
  });
}
if (opt('BOT_META_APP_ID') && opt('BOT_META_APP_SECRET')) {
  credentials.push({
    id: '80D44U2jieTOLmHl',
    name: 'WhatsApp OAuth account',
    type: 'whatsAppTriggerApi',
    data: { clientId: opt('BOT_META_APP_ID'), clientSecret: opt('BOT_META_APP_SECRET') },
  });
}
if (opt('BOT_SUPABASE_URL') && opt('BOT_SUPABASE_SERVICE_KEY')) {
  credentials.push({
    id: '23Tzwnj8bHd9gRZ3',
    name: 'Supabase account',
    type: 'supabaseApi',
    data: { host: opt('BOT_SUPABASE_URL'), serviceRole: opt('BOT_SUPABASE_SERVICE_KEY') },
  });
}

process.stdout.write(JSON.stringify(credentials, null, 2));
