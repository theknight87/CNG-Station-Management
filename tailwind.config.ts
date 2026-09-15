import type { Config } from 'tailwindcss'
import animate from 'tailwindcss-animate'

export default {
  darkMode: ['class'],
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    container: {
      center: true,
      padding: '2rem',
      screens: { '2xl': '1400px' },
    },
    extend: {
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: {
          DEFAULT: 'hsl(var(--primary))',
          foreground: 'hsl(var(--primary-foreground))',
        },
        secondary: {
          DEFAULT: 'hsl(var(--secondary))',
          foreground: 'hsl(var(--secondary-foreground))',
        },
        destructive: {
          DEFAULT: 'hsl(var(--destructive))',
          foreground: 'hsl(var(--destructive-foreground))',
        },
        muted: {
          DEFAULT: 'hsl(var(--muted))',
          foreground: 'hsl(var(--muted-foreground))',
        },
        accent: {
          DEFAULT: 'hsl(var(--accent))',
          foreground: 'hsl(var(--accent-foreground))',
        },
        card: {
          DEFAULT: 'hsl(var(--card))',
          foreground: 'hsl(var(--card-foreground))',
        },
        // Brand identity (Cargas / NGV). Deliberately a SEPARATE scale from
        // `status` below: brand marks identity, navigation and selection;
        // status states compliance. A component reaches for one or the other
        // and never treats them as interchangeable.
        brand: {
          DEFAULT: 'hsl(var(--brand))',
          fg: 'hsl(var(--brand-fg))',
          strong: 'hsl(var(--brand-strong))',
          'strong-fg': 'hsl(var(--brand-strong-fg))',
          deep: 'hsl(var(--brand-deep))',
          'deep-fg': 'hsl(var(--brand-deep-fg))',
          yellow: 'hsl(var(--brand-yellow))',
          'yellow-fg': 'hsl(var(--brand-yellow-fg))',
          'yellow-ink': 'hsl(var(--brand-yellow-ink))',
          rail: 'hsl(var(--brand-rail))',
        },

        // Semantic status colours (§15). Named by MEANING, never by hue, so a
        // palette change cannot silently alter what a badge asserts.
        status: {
          ok: 'hsl(var(--status-ok))',
          'ok-bg': 'hsl(var(--status-ok-bg))',
          'due-soon': 'hsl(var(--status-due-soon))',
          'due-soon-bg': 'hsl(var(--status-due-soon-bg))',
          overdue: 'hsl(var(--status-overdue))',
          'overdue-bg': 'hsl(var(--status-overdue-bg))',
          unmapped: 'hsl(var(--status-unmapped))',
          'unmapped-bg': 'hsl(var(--status-unmapped-bg))',
          conflict: 'hsl(var(--status-conflict))',
          'conflict-bg': 'hsl(var(--status-conflict-bg))',
          inactive: 'hsl(var(--status-inactive))',
          'inactive-bg': 'hsl(var(--status-inactive-bg))',
        },
      },
      spacing: {
        sidebar: 'var(--sidebar-width)',
        'sidebar-collapsed': 'var(--sidebar-width-collapsed)',
        header: 'var(--header-height)',
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 1px)',
        sm: 'calc(var(--radius) - 2px)',
      },
    },
  },
  plugins: [animate],
} satisfies Config
