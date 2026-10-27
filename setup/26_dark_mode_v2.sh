#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 26 (v2): dark mode switch on the website and the admin dashboard
#   - a round button in the bottom right corner of every page: moon for dark
#     mode, sun for light mode
#   - the choice is saved in the browser; until someone picks, the site follows
#     the phone or computer setting
#   - no flash of the wrong colours when a page opens
#   Website and admin dashboard. Safe to run even if the first script 26 already ran.
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/26_dark_mode_v2.sh
# =============================================================================
set -euo pipefail
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()  { red "ERROR: $*"; exit 1; }
PROD_FRONTEND="$(grep -E '^PRODUCTION_FRONTEND_URL=' backend/.env | tail -n1 | cut -d= -f2-)"

step "Checking the project"
grep -q "Questions people ask" frontend/src/app/page.tsx 2>/dev/null || fail "Run this from ~/dataonchain after script 25 (FAQ)"
if [[ -n "$(git status --porcelain | grep -v 'setup/26_dark_mode' || true)" ]]; then
  git status --short
  fail "There are uncommitted changes (listed above). Tell Claude before going on."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"
green "OK"

step "Writing the dark mode switch"
cat > "frontend/src/app/globals.css" <<'DOC_EOF'
@import "tailwindcss";

/* Dark mode follows the "dark" class on <html> (set by the theme switch, or
   from the phone or computer setting until the user picks one). */
@custom-variant dark (&:where(.dark, .dark *));

:root {
  --background: #ffffff;
  --foreground: #171717;
  color-scheme: light;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-geist-sans);
  --font-mono: var(--font-geist-mono);
}

:root.dark {
  --background: #0a0a0a;
  --foreground: #ededed;
  color-scheme: dark;
}

body {
  background: var(--background);
  color: var(--foreground);
  font-family: Arial, Helvetica, sans-serif;
}
DOC_EOF
cat > "frontend/src/components/ThemeToggle.tsx" <<'DOC_EOF'
"use client";

import { useEffect, useState } from "react";

// Light / dark switch, shown in the corner of every page. The choice is saved
// in this browser. Until the user picks one, the site follows the phone or
// computer setting (and changes with it).
const KEY = "theme";

function setTheme(dark: boolean, save: boolean) {
  const root = document.documentElement;
  root.classList.toggle("dark", dark);
  root.style.colorScheme = dark ? "dark" : "light";
  if (save) {
    try {
      localStorage.setItem(KEY, dark ? "dark" : "light");
    } catch {
      // private browsing: the choice lasts until the page is closed
    }
  }
}

export function ThemeToggle() {
  const [dark, setDark] = useState<boolean | null>(null);

  useEffect(() => {
    setDark(document.documentElement.classList.contains("dark"));
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const follow = () => {
      let saved: string | null = null;
      try {
        saved = localStorage.getItem(KEY);
      } catch {
        saved = null;
      }
      if (saved) return;
      setTheme(media.matches, false);
      setDark(media.matches);
    };
    media.addEventListener("change", follow);
    return () => media.removeEventListener("change", follow);
  }, []);

  function toggle() {
    const next = !document.documentElement.classList.contains("dark");
    setTheme(next, true);
    setDark(next);
  }

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={dark ? "Switch to light mode" : "Switch to dark mode"}
      title={dark ? "Light mode" : "Dark mode"}
      className="fixed bottom-4 right-4 z-50 flex h-11 w-11 items-center justify-center rounded-full border border-zinc-300 bg-white text-zinc-700 shadow-md transition hover:bg-zinc-50 print:hidden dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
    >
      {dark === null ? null : dark ? (
        // Sun: tap for light mode
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
        </svg>
      ) : (
        // Moon: tap for dark mode
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
        </svg>
      )}
    </button>
  );
}
DOC_EOF
cat > "frontend/src/app/layout.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { ThemeToggle } from "@/components/ThemeToggle";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "dataonchain",
  description: "Buy Nigerian airtime and data with USDC on Arc",
};

// Runs before the page is drawn, so there is no flash of the wrong colours:
// the saved choice, or else the phone or computer setting.
const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem("theme");var d=t==="dark"||(t!=="light"&&window.matchMedia("(prefers-color-scheme: dark)").matches);var r=document.documentElement;if(d){r.classList.add("dark")}else{r.classList.remove("dark")}r.style.colorScheme=d?"dark":"light"}catch(e){}})();`;

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body className="min-h-full flex flex-col">
        {children}
        <ThemeToggle />
      </body>
    </html>
  );
}
DOC_EOF
cat > "admin/src/app/globals.css" <<'DOC_EOF'
@import "tailwindcss";

/* Dark mode follows the "dark" class on <html> (set by the theme switch, or
   from the computer setting until the admin picks one). */
@custom-variant dark (&:where(.dark, .dark *));

:root {
  --background: #ffffff;
  --foreground: #171717;
  color-scheme: light;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-geist-sans);
  --font-mono: var(--font-geist-mono);
}

:root.dark {
  --background: #0a0a0a;
  --foreground: #ededed;
  color-scheme: dark;
}

body {
  background: var(--background);
  color: var(--foreground);
  font-family: var(--font-geist-sans), Arial, Helvetica, sans-serif;
}
DOC_EOF
cat > "admin/src/components/ThemeToggle.tsx" <<'DOC_EOF'
"use client";

import { useEffect, useState } from "react";

// Light / dark switch, shown in the corner of every page. The choice is saved
// in this browser. Until the user picks one, the site follows the phone or
// computer setting (and changes with it).
const KEY = "theme";

function setTheme(dark: boolean, save: boolean) {
  const root = document.documentElement;
  root.classList.toggle("dark", dark);
  root.style.colorScheme = dark ? "dark" : "light";
  if (save) {
    try {
      localStorage.setItem(KEY, dark ? "dark" : "light");
    } catch {
      // private browsing: the choice lasts until the page is closed
    }
  }
}

export function ThemeToggle() {
  const [dark, setDark] = useState<boolean | null>(null);

  useEffect(() => {
    setDark(document.documentElement.classList.contains("dark"));
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const follow = () => {
      let saved: string | null = null;
      try {
        saved = localStorage.getItem(KEY);
      } catch {
        saved = null;
      }
      if (saved) return;
      setTheme(media.matches, false);
      setDark(media.matches);
    };
    media.addEventListener("change", follow);
    return () => media.removeEventListener("change", follow);
  }, []);

  function toggle() {
    const next = !document.documentElement.classList.contains("dark");
    setTheme(next, true);
    setDark(next);
  }

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={dark ? "Switch to light mode" : "Switch to dark mode"}
      title={dark ? "Light mode" : "Dark mode"}
      className="fixed bottom-4 right-4 z-50 flex h-11 w-11 items-center justify-center rounded-full border border-zinc-300 bg-white text-zinc-700 shadow-md transition hover:bg-zinc-50 print:hidden dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
    >
      {dark === null ? null : dark ? (
        // Sun: tap for light mode
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
        </svg>
      ) : (
        // Moon: tap for dark mode
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
        </svg>
      )}
    </button>
  );
}
DOC_EOF
cat > "admin/src/app/layout.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Geist, Geist_Mono } from "next/font/google";
import { ThemeToggle } from "@/components/ThemeToggle";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "dataonchain admin",
  description: "Private admin dashboard",
  robots: { index: false, follow: false },
};

// Runs before the page is drawn, so there is no flash of the wrong colours:
// the saved choice, or else the phone or computer setting.
const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem("theme");var d=t==="dark"||(t!=="light"&&window.matchMedia("(prefers-color-scheme: dark)").matches);var r=document.documentElement;if(d){r.classList.add("dark")}else{r.classList.remove("dark")}r.style.colorScheme=d?"dark":"light"}catch(e){}})();`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body className="min-h-full">
        {children}
        <ThemeToggle />
      </body>
    </html>
  );
}
DOC_EOF
green "OK"

step "Website and admin dashboard: build"
if ! (cd frontend && npm run build) || ! (cd admin && npm run build); then
  git checkout -- frontend admin
  git clean -fq frontend/src/components/ThemeToggle.tsx admin/src/components/ThemeToggle.tsx
  fail "A build failed (details above). The change was undone and nothing was committed. Paste the output to Claude."
fi
green "OK"

step "Committing to GitHub"
git add frontend/src/app/globals.css frontend/src/components/ThemeToggle.tsx frontend/src/app/layout.tsx \
  admin/src/app/globals.css admin/src/components/ThemeToggle.tsx admin/src/app/layout.tsx setup/26_dark_mode*.sh
git commit -q -m "Dark mode switch on the website and the admin dashboard" || echo "Nothing new to commit"
git push
green "OK: pushed."

ADMIN_SITE="$(grep -E '^PRODUCTION_ADMIN_URL=' backend/.env | tail -n1 | cut -d= -f2-)"
printf 'Waiting for Vercel to publish '
for _ in $(seq 1 30); do
  if curl -s --max-time 20 "$PROD_FRONTEND/" | grep -q 'localStorage.getItem(\\"theme\\")\|localStorage.getItem("theme")'; then
    echo; green "OK: dark mode is live on the website"
    break
  fi
  printf '.'; sleep 10
done
echo
green "Script 26 complete."
echo "  Website: $PROD_FRONTEND  (moon button, bottom right)"
echo "  Admin:   ${ADMIN_SITE:-your admin dashboard}  (same button, after Vercel finishes in about 2 minutes)"
