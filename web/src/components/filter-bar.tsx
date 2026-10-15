'use client';

import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useRef, useState, useTransition } from 'react';
import { Search, SlidersHorizontal, X } from 'lucide-react';
import { activityLabel, activityMeta, titleCase } from '@/lib/activities';
import type { Facet, Filters } from '@/lib/board';
import { inputClass } from './ui';

const WHEN_LABEL = { upcoming: 'Any upcoming day', today: 'Today', tomorrow: 'Tomorrow', weekend: 'This weekend', week: 'Next 7 days', any: 'Any day, past too' };
const PART_LABEL = { '': 'Any time', morning: 'Morning', afternoon: 'Afternoon', evening: 'Evening', night: 'Night' };
const STATUS_LABEL = { active: 'Still looking', looking: 'Looking, no match yet', matched: 'Full', all: 'Everything' };
const LEVEL_LABEL = { '': 'Any level', beginner: 'Beginner', intermediate: 'Intermediate', advanced: 'Advanced' };

// defaults are left out of the URL, so a clean board has a clean link
const DEFAULTS: Record<string, string> = { when: 'upcoming', status: 'active' };

const selectClass = `${inputClass} appearance-none cursor-pointer pr-9 bg-[url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='none' stroke='%2341454d' stroke-width='2' viewBox='0 0 24 24'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E")] bg-[length:16px] bg-[right_12px_center] bg-no-repeat`;

export function FilterBar({ filters, activities, cities }: { filters: Filters; activities: Facet[]; cities: Facet[] }) {
  const router = useRouter();
  const path = usePathname();
  const [pending, start] = useTransition();
  const [q, setQ] = useState(filters.q);
  const [more, setMore] = useState(Boolean(filters.part || filters.level || filters.status !== 'active'));
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);

  const go = (patch: Partial<Record<keyof Filters, string>>) => {
    const next: Record<string, string> = {
      q: filters.q, activity: filters.activity, city: filters.city, when: filters.when,
      part: filters.part, status: filters.status, level: filters.level, ...patch,
    };
    const sp = new URLSearchParams();
    for (const [k, v] of Object.entries(next)) if (v && v !== DEFAULTS[k]) sp.set(k, v);
    const qs = sp.toString();
    start(() => router.replace(qs ? `${path}?${qs}` : path, { scroll: false }));
  };

  // typing searches after a short pause
  useEffect(() => {
    if (q === filters.q) return;
    clearTimeout(timer.current);
    timer.current = setTimeout(() => go({ q: q.trim() }), 300);
    return () => clearTimeout(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  const active = [filters.q, filters.activity, filters.city, filters.part, filters.level].filter(Boolean).length
    + (filters.when !== 'upcoming' ? 1 : 0) + (filters.status !== 'active' ? 1 : 0);

  return (
    <section aria-label="Filters" className="flex flex-col gap-4" data-pending={pending || undefined}>
      <div className="flex flex-col gap-3 sm:flex-row">
        <label className="relative flex-1">
          <span className="sr-only">Search</span>
          <Search className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-border-strong" aria-hidden />
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search an area, city, sport or name"
            className={`${inputClass} pl-10`}
          />
        </label>
        <div className="grid grid-cols-2 gap-3 sm:flex">
          <label className="sm:w-44">
            <span className="sr-only">City</span>
            <select value={filters.city} onChange={(e) => go({ city: e.target.value })} className={selectClass}>
              <option value="">All cities</option>
              {cities.map((c) => <option key={c.value} value={c.value}>{titleCase(c.value)}{c.n ? ` (${c.n})` : ''}</option>)}
              {filters.city && !cities.some((c) => c.value === filters.city) && <option value={filters.city}>{titleCase(filters.city)}</option>}
            </select>
          </label>
          <label className="sm:w-44">
            <span className="sr-only">Day</span>
            <select value={filters.when} onChange={(e) => go({ when: e.target.value })} className={selectClass}>
              {Object.entries(WHEN_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
        </div>
        <button
          type="button"
          onClick={() => setMore((m) => !m)}
          aria-expanded={more}
          className="inline-flex h-11 items-center justify-center gap-2 rounded-sm border border-hairline bg-canvas px-4 text-body text-ink hover:bg-surface-soft"
        >
          <SlidersHorizontal className="size-4" aria-hidden />More
        </button>
      </div>

      {more && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <label className="flex flex-col gap-1.5">
            <span className="text-caption font-medium text-muted">Time of day</span>
            <select value={filters.part} onChange={(e) => go({ part: e.target.value })} className={selectClass}>
              {Object.entries(PART_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-1.5">
            <span className="text-caption font-medium text-muted">Status</span>
            <select value={filters.status} onChange={(e) => go({ status: e.target.value })} className={selectClass}>
              {Object.entries(STATUS_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-1.5">
            <span className="text-caption font-medium text-muted">Skill level</span>
            <select value={filters.level} onChange={(e) => go({ level: e.target.value })} className={selectClass}>
              {Object.entries(LEVEL_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
        </div>
      )}

      <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 no-scrollbar sm:mx-0 sm:flex-wrap sm:px-0" role="group" aria-label="Activity">
        <Chip on={!filters.activity} onClick={() => go({ activity: '' })}>All sports</Chip>
        {activities.map((a) => (
          <Chip key={a.value} on={filters.activity === a.value} onClick={() => go({ activity: filters.activity === a.value ? '' : a.value })}>
            <span aria-hidden>{activityMeta(a.value).emoji}</span>{activityLabel(a.value)}
            {a.n > 0 && <span className="text-caption opacity-70">{a.n}</span>}
          </Chip>
        ))}
      </div>

      {active > 0 && (
        <button
          type="button"
          onClick={() => { setQ(''); go({ q: '', activity: '', city: '', when: 'upcoming', part: '', status: 'active', level: '' }); }}
          className="inline-flex items-center gap-1.5 self-start text-body text-link hover:text-link-active"
        >
          <X className="size-4" aria-hidden />Clear {active} {active === 1 ? 'filter' : 'filters'}
        </button>
      )}
    </section>
  );
}

function Chip({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={on}
      className={`inline-flex shrink-0 items-center gap-1.5 rounded-full border px-3.5 py-1.5 text-body transition-colors ${
        on ? 'border-primary bg-primary text-on-primary' : 'border-hairline bg-canvas text-ink hover:bg-surface-soft'}`}
    >
      {children}
    </button>
  );
}
