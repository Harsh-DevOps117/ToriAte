import Image from 'next/image';
import type { LucideIcon } from 'lucide-react';

// Same look as ToriGoogle's web app (../ToriGoogle/web/src/components/ui.tsx).
type Variant = 'primary' | 'secondary' | 'ghost';
type Size = 'md' | 'sm';

const VARIANT: Record<Variant, string> = {
  primary: 'bg-primary text-on-primary hover:bg-primary-active active:bg-primary-active shadow-[0_1px_2px_rgba(27,97,201,0.18)]',
  secondary: 'bg-canvas text-ink border border-hairline hover:bg-surface-soft active:bg-surface-soft',
  ghost: 'bg-transparent text-ink hover:bg-surface-soft active:bg-surface-soft',
};
const SIZE: Record<Size, string> = {
  md: 'px-6 py-3.5 text-label',
  sm: 'px-4 py-2 text-body',
};

export function btn(variant: Variant = 'primary', size: Size = 'md', extra = '') {
  return `inline-flex items-center justify-center gap-2 rounded-lg font-medium whitespace-nowrap cursor-pointer select-none transition-colors disabled:opacity-45 disabled:cursor-not-allowed ${VARIANT[variant]} ${SIZE[size]} ${extra}`;
}

export const inputClass =
  'h-11 w-full rounded-sm border border-hairline bg-canvas px-4 text-body text-ink placeholder:text-border-strong outline-none focus:border-info-border focus:ring-1 focus:ring-info-border';

export function Logo({ size = 32 }: { size?: number }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <Image src="/logo.webp" alt="" width={size} height={size} priority className="rounded-full" />
      <span className="font-display text-title-md leading-none text-ink">Tori</span>
    </span>
  );
}

export function Stat({ label, value, icon: Icon, hint }: { label: string; value: string | number; icon: LucideIcon; hint?: string }) {
  return (
    <div className="flex flex-col gap-3 rounded-lg border border-hairline bg-canvas p-5">
      <span className="flex items-center gap-2 text-caption text-muted"><Icon className="size-4" aria-hidden />{label}</span>
      <span className="font-display text-title-lg font-normal text-ink">{value}</span>
      {hint && <span className="text-caption text-muted">{hint}</span>}
    </div>
  );
}
