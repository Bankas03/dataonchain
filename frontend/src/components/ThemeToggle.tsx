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
