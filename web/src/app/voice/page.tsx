import type { Metadata } from 'next';
import { VoiceAgent } from '@/components/voice-agent';

export const metadata: Metadata = {
  title: 'Harsh AI',
  description: 'Talk to Harsh AI: ask about Harsh Kharwar’s experience, projects and skills.',
};

// Read the keys when the page is served, not at build time: the Docker image is built without them.
export const dynamic = 'force-dynamic';

export default function VoicePage() {
  // Both are public: the key is a Vapi *public* key, limited in the Vapi dashboard to this site's
  // origins and to this assistant. The private key (VAPI_PRIVATE_API_KEY) never reaches the browser.
  const publicKey = process.env.NEXT_PUBLIC_VAPI_PUBLIC_KEY || '';
  const assistantId = process.env.VAPI_ASSISTANT_ID || 'afd96ebf-40a7-40d2-bc0b-b6b94367e588';
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col px-4 py-8 sm:px-6 sm:py-12">
      <VoiceAgent publicKey={publicKey} assistantId={assistantId} />
    </main>
  );
}
