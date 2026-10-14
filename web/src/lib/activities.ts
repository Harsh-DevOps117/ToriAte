// Canonical activity names come from the bot's LLM prompt (plan/build_partner_workflow.py, "activity").
type Meta = { emoji: string; tone: string };

const META: Record<string, Meta> = {
  football: { emoji: '⚽', tone: 'bg-sig-mint' },
  cricket: { emoji: '🏏', tone: 'bg-sig-cream' },
  badminton: { emoji: '🏸', tone: 'bg-sig-yellow' },
  tennis: { emoji: '🎾', tone: 'bg-sig-yellow' },
  table_tennis: { emoji: '🏓', tone: 'bg-sig-peach' },
  pickleball: { emoji: '🏓', tone: 'bg-sig-mint' },
  padel: { emoji: '🎾', tone: 'bg-sig-cream' },
  basketball: { emoji: '🏀', tone: 'bg-sig-peach' },
  volleyball: { emoji: '🏐', tone: 'bg-sig-cream' },
  squash: { emoji: '🎾', tone: 'bg-sig-peach' },
  running: { emoji: '🏃', tone: 'bg-sig-mint' },
  cycling: { emoji: '🚴', tone: 'bg-sig-yellow' },
  swimming: { emoji: '🏊', tone: 'bg-sig-mint' },
  gym: { emoji: '🏋️', tone: 'bg-sig-peach' },
  yoga: { emoji: '🧘', tone: 'bg-sig-cream' },
  hiking: { emoji: '🥾', tone: 'bg-sig-mint' },
  chess: { emoji: '♟️', tone: 'bg-sig-cream' },
};

export function activityMeta(a: string): Meta {
  return META[a] || { emoji: '🤝', tone: 'bg-surface-strong' };
}

export function activityLabel(a: string) {
  const s = a.replace(/_/g, ' ');
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export function titleCase(s: string) {
  return s.replace(/\b\p{L}/gu, (c) => c.toUpperCase());
}
