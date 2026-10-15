import { CalendarDays, Clock, MapPin, UserPlus, Users } from 'lucide-react';
import { activityLabel, activityMeta, titleCase } from '@/lib/activities';
import type { BoardRequest } from '@/lib/board';
import { btn } from './ui';

const ZONE = 'Asia/Kolkata';
const STATUS: Record<BoardRequest['board_status'], { label: string; className: string }> = {
  looking: { label: 'Looking', className: 'bg-sig-mint' },
  in_talks: { label: 'Confirming', className: 'bg-sig-yellow' },
  matched: { label: 'Full', className: 'bg-sig-cream' },
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


export function RequestCard({ r, bot, index = 0 }: { r: BoardRequest; bot: string; index?: number }) {
  const meta = activityMeta(r.activity);
  const st = STATUS[r.board_status];
  const name = r.first_name && /\p{L}/u.test(r.first_name) ? r.first_name : 'Someone';
  const open = r.board_status === 'looking' || r.board_status === 'in_talks';
  const need = r.players_needed > 1 ? `${r.players_needed} people` : 'a partner';
  const left = Math.max(0, r.players_needed - r.joined_count);

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
        <div className="flex items-start gap-2.5">
          <Users className="mt-0.5 size-4 shrink-0 text-muted" aria-hidden />
          <dt className="sr-only">Who&apos;s in</dt>
          <dd className="flex min-w-0 flex-col gap-1.5">
            <span>
              {r.joined_count}/{r.players_needed} joined
              {open && left > 0 && <span className="text-muted"> · {left} {left === 1 ? 'spot' : 'spots'} left</span>}
            </span>
            {r.joined_names.length > 0 && (
              <span className="flex flex-wrap gap-1.5">
                {r.joined_names.map((n, i) => (
                  <span key={i} className="inline-flex items-center gap-1 rounded-full bg-surface-soft px-2 py-0.5 text-caption text-ink">
                    <span className="inline-flex size-4 items-center justify-center rounded-full bg-sig-mint text-[10px] font-semibold">{n.charAt(0).toUpperCase()}</span>
                    {n}
                  </span>
                ))}
              </span>
            )}
          </dd>
        </div>
        {r.skill_level && (
          <div className="flex items-center gap-2.5 pl-[26px]">
            <span className="rounded-full border border-hairline px-2 text-caption capitalize">{r.skill_level}</span>
          </div>
        )}
      </dl>

      {r.notes && <p className="rounded-md bg-surface-soft px-3 py-2 text-body text-body">“{r.notes}”</p>}

      <footer className="mt-auto flex items-center justify-between gap-3 border-t border-hairline pt-4">
        <span className="flex items-center gap-1.5 text-caption text-muted"><Clock className="size-3.5" aria-hidden />Posted {ago(r.created_at)}</span>
        {open && bot && r.join_code && left > 0 && (
          <a
            href={`https://wa.me/${bot}?text=${encodeURIComponent(`JOIN ${r.join_code}`)}`}
            target="_blank"
            rel="noopener noreferrer"
            className={btn('primary', 'sm', '!px-3 !py-1.5')}
            title={`Opens WhatsApp with "JOIN ${r.join_code}". ${name} gets your profile and decides; numbers are shared only if they accept.`}
          >
            <UserPlus className="size-4" aria-hidden />Join
          </a>
        )}
      </footer>
    </article>
  );
}
