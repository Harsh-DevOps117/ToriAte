import Link from 'next/link';
import { CalendarCheck2, HeartHandshake, MessageCircle, Search, Trophy } from 'lucide-react';
import { FilterBar } from '@/components/filter-bar';
import { LiveRefresh } from '@/components/live-refresh';
import { RequestCard } from '@/components/request-card';
import { btn, Logo, Stat } from '@/components/ui';
import { botNumber, DEFAULT_LIMIT, getOverview, getRequests, parseFilters } from '@/lib/board';

export default async function BoardPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const sp = await searchParams;
  const filters = parseFilters(sp);
  const [{ items, total }, { stats, activities, cities }] = await Promise.all([getRequests(filters), getOverview()]);
  const bot = botNumber();
  const post = bot ? `https://wa.me/${bot}?text=${encodeURIComponent('Hi Tori! I want to find a partner to play with')}` : null;

  const moreHref = (() => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(sp)) if (typeof v === 'string' && k !== 'limit') q.set(k, v);
    q.set('limit', String(filters.limit + DEFAULT_LIMIT));
    return `/?${q}`;
  })();

  return (
    <div className="min-h-dvh overflow-x-clip bg-page">
      <nav className="sticky top-0 z-40 h-16 border-b border-ink/8 bg-page/85 backdrop-blur">
        <div className="mx-auto flex h-full max-w-content items-center justify-between gap-4 px-4 sm:px-12">
          <Link href="/" aria-label="Tori partner board"><Logo /></Link>
          <div className="flex items-center gap-3">
            <span className="hidden sm:inline"><LiveRefresh renderedAt={new Date().toISOString()} /></span>
            <Link href="/wallet" className={btn('secondary', 'sm')}>Wallet</Link>
            {post && (
              <a href={post} target="_blank" rel="noopener noreferrer" className={btn('primary', 'sm')}>
                <MessageCircle className="size-4" aria-hidden />Post a request
              </a>
            )}
          </div>
        </div>
      </nav>

      <main className="mx-auto flex max-w-content flex-col gap-10 px-4 py-10 sm:px-12 sm:py-14">
        <header className="flex flex-col gap-5">
          <span className="sm:hidden"><LiveRefresh renderedAt={new Date().toISOString()} /></span>
          <h1 className="max-w-3xl font-display text-display-lg font-normal text-ink sm:text-display-xl">
            Find someone to play with.
          </h1>
          <p className="max-w-2xl text-title-sm text-muted">
            Every game people post to Tori on WhatsApp, as it happens. Spot one you like? Tap{' '}
            <span className="font-medium text-ink">Join</span>: WhatsApp opens with a code, you send it, and the organiser gets your
            profile. Numbers are only shared once they say yes.
          </p>
        </header>

        <section aria-label="Right now" className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <Stat label="Looking right now" value={stats.looking} icon={Search} hint={`${stats.active - stats.looking} more confirming a partner`} />
          <Stat label="Games today" value={stats.today} icon={CalendarCheck2} hint="requested for today" />
          <Stat label="Filled this week" value={stats.matched_week} icon={HeartHandshake} hint="games with every spot taken" />
          <Stat label="Sports" value={stats.activities} icon={Trophy} hint="with someone looking" />
        </section>

        <FilterBar filters={filters} activities={activities} cities={cities} />

        <section aria-label="Requests" className="flex flex-col gap-5">
          <p className="text-body text-muted" aria-live="polite">
            {total === 0 ? 'No requests match.' : `${total} ${total === 1 ? 'request' : 'requests'}`}
            {total > items.length ? `, showing ${items.length}` : ''}
          </p>

          {items.length === 0 ? (
            <div className="flex flex-col items-start gap-3 rounded-lg bg-canvas p-8">
              <p className="font-display text-title-md text-ink">Nobody here yet.</p>
              <p className="max-w-lg text-body text-muted">
                Try another day or city, or be the first: tell Tori on WhatsApp what you want to play, when and where,
                for example “Badminton tomorrow 7 pm in HSR Layout, Bangalore”.
              </p>
              {post && <a href={post} target="_blank" rel="noopener noreferrer" className={btn('primary', 'sm')}><MessageCircle className="size-4" aria-hidden />Post a request</a>}
            </div>
          ) : (
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {items.map((r, i) => <RequestCard key={r.id} r={r} bot={bot} index={i} />)}
            </div>
          )}

          {total > items.length && (
            <Link href={moreHref} scroll={false} className={btn('secondary', 'sm', 'self-center')}>Show more</Link>
          )}
        </section>
      </main>

      <footer className="border-t border-hairline">
        <div className="mx-auto flex max-w-content flex-col gap-2 px-4 py-8 text-caption text-muted sm:flex-row sm:justify-between sm:px-12">
          <span>Tori · partner board</span>
          <span>Only first names, places and times are shown here. Phone numbers never are.</span>
        </div>
      </footer>
    </div>
  );
}
