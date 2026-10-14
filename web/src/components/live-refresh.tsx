'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';

// New WhatsApp requests show up without a reload: the page re-renders on the server every
// `seconds` while the tab is visible, and right away when you come back to it.
export function LiveRefresh({ seconds = 20, renderedAt }: { seconds?: number; renderedAt: string }) {
  const router = useRouter();
  const [time, setTime] = useState('');

  useEffect(() => {
    setTime(new Intl.DateTimeFormat('en-IN', { hour: 'numeric', minute: '2-digit', second: '2-digit' }).format(new Date(renderedAt)));
  }, [renderedAt]);

  useEffect(() => {
    const tick = () => { if (document.visibilityState === 'visible') router.refresh(); };
    const id = setInterval(tick, seconds * 1000);
    document.addEventListener('visibilitychange', tick);
    return () => { clearInterval(id); document.removeEventListener('visibilitychange', tick); };
  }, [router, seconds]);

  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-hairline bg-canvas px-3 py-1 text-caption text-muted">
      <span className="live-dot size-2 rounded-full bg-success-border" aria-hidden />
      Live{time ? <> · updated {time}</> : null}
    </span>
  );
}
