import { CalendarDays, Clock, MapPin, MessageCircle, Users } from 'lucide-react';
import { activityLabel, activityMeta, titleCase } from '@/lib/activities';
import type { BoardRequest } from '@/lib/board';
import { btn } from './ui';

const ZONE = 'Asia/Kolkata';
const STATUS: Record<BoardRequest['board_status'], { label: string; className: string }> = {
  looking: { label: 'Looking', className: 'bg-sig-mint' },
  in_talks: { label: 'Confirming', className: 'bg-sig-yellow' },
  matched: { label: 'Matched', className: 'bg-sig-cream' },
  closed: { label: 'Closed', className: 'bg-surface-strong' },
};

function istDate(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400e3);
  return new Intl.DateTimeFormat('en-CA', { timeZone: ZONE }).format(d); // YYYY-MM-DD
}

export function dayLabel(playDate: string) {
  if (playDate === istDate(0)) return 'Today';
  if (playDate === istDate(1)) return 'Tomorrow';
  if (playDate === istDate(-1)) return 'Yesterday';
  const [y, m, d] = playDate.split('-').map(Number);
  return new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' })
    .format(new Date(Date.UTC(y, m - 1, d)));
}

export function ago(iso: string) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto', style: 'short' });
  if (s < 3600) return rtf.format(-Math.round(s / 60), 'minute');
  if (s < 86400) return rtf.format(-Math.round(s / 3600), 'hour');
  return rtf.format(-Math.round(s / 86400), 'day');
}

// What someone would send the bot to look for the same game
function joinText(r: BoardRequest) {
  const day = dayLabel(r.play_date);
  const when = day === 'Today' || day === 'Tomorrow' ? day.toLowerCase() : 'on ' + day;
  const where = [r.area, r.city && titleCase(r.city)].filter(Boolean).join(', ');
  return `${activityLabel(r.activity)} partner ${when} ${r.time_label || ''}${where ? ' in ' + where : ''}`.replace(/\s+/g, ' ').trim();
}

export function RequestCard({ r, bot, index = 0 }: { r: BoardRequest; bot: string; index?: number }) {
  const meta = activityMeta(r.activity);
  const st = STATUS[r.board_status];
  const name = r.first_name && /\p{L}/u.test(r.first_name) ? r.first_name : 'Someone';
  const open = r.board_status === 'looking' || r.board_status === 'in_talks';
  const need = r.players_needed > 1 ? `${r.players_needed} players` : 'a partner';

  return (
    <article
      className={`rise flex flex-col gap-4 rounded-lg border border-hairline bg-canvas p-5 transition-shadow hover:shadow-[0_6px_24px_rgba(24,29,38,0.08)] ${open ? '' : 'opacity-75'}`}
      style={{ animationDelay: `${Math.min(index, 12) * 35}ms` }}
    >
      <header className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-3">
          <span className={`inline-flex size-11 shrink-0 items-center justify-center rounded-full text-[22px] ${meta.tone}`} aria-hidden>
            {meta.emoji}
          </span>
          <div className="flex min-w-0 flex-col">
            <h3 className="truncate font-display text-title-sm font-normal text-ink">{activityLabel(r.activity)}</h3>
            <p className="truncate text-caption text-muted">{name} is looking for {need}</p>
          </div>
        </div>
        <span className={`shrink-0 rounded-full px-2.5 py-0.5 text-caption font-medium text-ink ${st.className}`}>{st.label}</span>
      </header>

      <dl className="grid gap-2 text-body text-ink">
        <div className="flex items-center gap-2.5">
          <CalendarDays className="size-4 shrink-0 text-muted" aria-hidden />
          <dt className="sr-only">When</dt>
          <dd>{dayLabel(r.play_date)}{r.time_label ? <span className="text-muted"> · {r.time_label}</span> : null}</dd>
        </div>
        <div className="flex items-center gap-2.5">
          <MapPin className="size-4 shrink-0 text-muted" aria-hidden />
          <dt className="sr-only">Where</dt>
          <dd className="truncate">{r.area || 'Anywhere'}{r.city ? <span className="text-muted">, {titleCase(r.city)}</span> : null}</dd>
        </div>
        {(r.skill_level || r.players_needed > 1) && (
          <div className="flex items-center gap-2.5">
            <Users className="size-4 shrink-0 text-muted" aria-hidden />
            <dt className="sr-only">Group</dt>
            <dd className="flex flex-wrap gap-1.5">
              {r.skill_level && <span className="rounded-full border border-hairline px-2 text-caption capitalize">{r.skill_level}</span>}
              {r.players_needed > 1 && <span className="rounded-full border border-hairline px-2 text-caption">needs {r.players_needed}</span>}
            </dd>
          </div>
        )}
      </dl>

      {r.notes && <p className="rounded-md bg-surface-soft px-3 py-2 text-body text-body">“{r.notes}”</p>}

      <footer className="mt-auto flex items-center justify-between gap-3 border-t border-hairline pt-4">
        <span className="flex items-center gap-1.5 text-caption text-muted"><Clock className="size-3.5" aria-hidden />Posted {ago(r.created_at)}</span>
        {open && bot && (
          <a
            href={`https://wa.me/${bot}?text=${encodeURIComponent(joinText(r))}`}
            target="_blank"
            rel="noopener noreferrer"
            className={btn('primary', 'sm', '!px-3 !py-1.5')}
            title="Tell Tori you want to play this game too. Tori asks you both before sharing numbers."
          >
            <MessageCircle className="size-4" aria-hidden />I&apos;m in
          </a>
        )}
      </footer>
    </article>
  );
}
