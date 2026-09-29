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

process.stdout.write(JSON.stringify(credentials, null, 2));
