import { rows } from './db';

// Everything here reads public.v_partner_board (db/migrations/007_partner_board.repeatable.sql):
// first names only, never phone numbers.

export const WHEN = ['upcoming', 'today', 'tomorrow', 'weekend', 'week', 'any'] as const;
export const PARTS = ['morning', 'afternoon', 'evening', 'night'] as const;
export const STATUSES = ['active', 'looking', 'matched', 'all'] as const;
export const LEVELS = ['beginner', 'intermediate', 'advanced'] as const;

export type When = (typeof WHEN)[number];
export type Part = (typeof PARTS)[number];
export type Status = (typeof STATUSES)[number];
export type Level = (typeof LEVELS)[number];

export type Filters = {
  q: string;
  activity: string;
  city: string;
  when: When;
  part: Part | '';
  status: Status;
  level: Level | '';
  limit: number;
};

export type BoardRequest = {
  id: string;
  first_name: string | null;
  activity: string;
  city: string | null;
  area: string | null;
  play_date: string;          // YYYY-MM-DD (India)
  time_label: string | null;
  day_part: Part;
  window_start: string;
  skill_level: Level | null;
  players_needed: number;
  notes: string | null;
  board_status: 'looking' | 'in_talks' | 'matched' | 'closed';   // matched = Full
  created_at: string;
  join_code: string | null;      // "JOIN <code>" on WhatsApp asks the creator to let you in
  joined_count: number;
  joined_names: string[];        // first names, in the order they joined
};

export type Facet = { value: string; n: number };
export type Stats = { looking: number; active: number; today: number; matched_week: number; activities: number };

export const DEFAULT_LIMIT = 48;

type Raw = Record<string, string | string[] | undefined>;

function one<T extends string>(v: string | string[] | undefined, allowed: readonly T[], fallback: T): T;
function one<T extends string>(v: string | string[] | undefined, allowed: readonly T[]): T | '';
function one<T extends string>(v: string | string[] | undefined, allowed: readonly T[], fallback: T | '' = ''): T | '' {
  const s = Array.isArray(v) ? v[0] : v;
  return allowed.includes(s as T) ? (s as T) : fallback;
}

const text = (v: string | string[] | undefined, max = 60) => (Array.isArray(v) ? v[0] : v || '').trim().slice(0, max);

export function parseFilters(sp: Raw): Filters {
  const limit = Number.parseInt(text(sp.limit, 4), 10);
  return {
    q: text(sp.q),
    activity: text(sp.activity, 40).toLowerCase(),
    city: text(sp.city, 40).toLowerCase(),
    when: one(sp.when, WHEN, 'upcoming'),
    part: one(sp.part, PARTS),
    status: one(sp.status, STATUSES, 'active'),
    level: one(sp.level, LEVELS),
    limit: Number.isFinite(limit) ? Math.min(Math.max(limit, DEFAULT_LIMIT), 240) : DEFAULT_LIMIT,
  };
}

const TODAY = "(now() AT TIME ZONE 'Asia/Kolkata')::date";

export async function getRequests(f: Filters): Promise<{ items: BoardRequest[]; total: number }> {
  const where: string[] = [];
  const args: unknown[] = [];
  const p = (v: unknown) => `$${args.push(v)}`;

  if (f.status === 'active') where.push("board_status IN ('looking', 'in_talks')");
  else if (f.status === 'looking') where.push("board_status = 'looking'");
  else if (f.status === 'matched') where.push("board_status = 'matched'");

  if (f.activity) where.push(`activity = ${p(f.activity)}`);
  if (f.city) where.push(`city = ${p(f.city)}`);
  if (f.part) where.push(`day_part = ${p(f.part)}`);
  if (f.level) where.push(`skill_level = ${p(f.level)}`);
  if (f.q) {
    const like = p('%' + f.q.replace(/[\\%_]/g, (c) => '\\' + c) + '%');
    where.push(`(area ILIKE ${like} OR city ILIKE ${like} OR replace(activity, '_', ' ') ILIKE ${like} `
             + `OR notes ILIKE ${like} OR first_name ILIKE ${like})`);
  }
  switch (f.when) {
    case 'upcoming': where.push('window_end > now()'); break;
    case 'today': where.push(`play_date = ${TODAY}`); break;
    case 'tomorrow': where.push(`play_date = ${TODAY} + 1`); break;
    case 'weekend': where.push(`play_date BETWEEN ${TODAY} AND ${TODAY} + 6 AND extract(isodow FROM play_date) IN (6, 7)`); break;
    case 'week': where.push(`play_date BETWEEN ${TODAY} AND ${TODAY} + 6`); break;
  }

  const list = await rows<BoardRequest & { total: string }>(`
    SELECT id, first_name, activity, city, area, to_char(play_date, 'YYYY-MM-DD') AS play_date, time_label, day_part,
           window_start, skill_level, players_needed, notes, board_status, created_at,
           join_code, joined_count, joined_names,
           count(*) OVER () AS total
      FROM public.v_partner_board
     ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
     ORDER BY window_end > now() DESC,
              CASE WHEN window_end > now() THEN window_start END ASC,
              window_start DESC
     LIMIT ${p(f.limit)}`, args);
  return {
    items: list.map(({ total: _total, ...r }) => r),
    total: list.length ? Number(list[0].total) : 0,
  };
}

export async function getOverview(): Promise<{ stats: Stats; activities: Facet[]; cities: Facet[] }> {
  const [stats, activities, cities] = await Promise.all([
    rows<Record<keyof Stats, string>>(`
      SELECT count(*) FILTER (WHERE board_status = 'looking') AS looking,
             count(*) FILTER (WHERE board_status IN ('looking', 'in_talks')) AS active,
             count(*) FILTER (WHERE play_date = ${TODAY} AND board_status <> 'closed') AS today,
             count(*) FILTER (WHERE board_status = 'matched' AND updated_at > now() - interval '7 days') AS matched_week,
             count(DISTINCT activity) FILTER (WHERE board_status IN ('looking', 'in_talks')) AS activities
        FROM public.v_partner_board`),
    // every activity / city seen in the last 90 days, busiest first, so the filters never look empty
    rows<{ value: string; n: string }>(`
      SELECT activity AS value, count(*) FILTER (WHERE board_status IN ('looking', 'in_talks')) AS n
        FROM public.v_partner_board WHERE created_at > now() - interval '90 days'
       GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 24`),
    rows<{ value: string; n: string }>(`
      SELECT city AS value, count(*) FILTER (WHERE board_status IN ('looking', 'in_talks')) AS n
        FROM public.v_partner_board WHERE city IS NOT NULL AND created_at > now() - interval '90 days'
       GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 40`),
  ]);
  const s = stats[0];
  const num = (k: keyof Stats) => Number(s?.[k] || 0);
  const facet = (r: { value: string; n: string }[]) => r.map((x) => ({ value: x.value, n: Number(x.n) }));
  return {
    stats: { looking: num('looking'), active: num('active'), today: num('today'), matched_week: num('matched_week'), activities: num('activities') },
    activities: facet(activities),
    cities: facet(cities),
  };
}

// "Join on WhatsApp": a message to the bot that describes the same game, so the bot's own matching
// (with both people's consent) puts them in touch. Nothing on the board reveals anyone's number.
export function botNumber() {
  return (process.env.BOARD_WHATSAPP_NUMBER || '').replace(/\D/g, '');
}
