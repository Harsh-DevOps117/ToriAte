import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: { default: 'Partner board · Tori', template: '%s · Tori' },
  description: 'Every request for a sports or hobby partner sent to Tori on WhatsApp, live. Find someone to play with near you.',
};

export const viewport: Viewport = {
  themeColor: '#e8ebe6',
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en-IN">
      <body>{children}</body>
    </html>
  );
}
