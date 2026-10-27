"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "./api";

// Loads one admin API path. Pass null to wait. reload() fetches it again.
export function useLoad<T>(path: string | null) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (!path) return;
    let stop = false;
    setLoading(true);
    api<T>(path)
      .then((d) => {
        if (stop) return;
        setData(d);
        setError(null);
      })
      .catch((e: unknown) => {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this page.");
      })
      .finally(() => {
        if (!stop) setLoading(false);
      });
    return () => {
      stop = true;
    };
  }, [path, tick]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { data, error, loading, reload };
}

// Reads ?name=value from the address bar once, after the page loads.
export function useQueryParam(name: string, fallback = ""): [string, (v: string) => void, boolean] {
  const [value, setValue] = useState(fallback);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const v = new URLSearchParams(window.location.search).get(name);
    if (v !== null) setValue(v);
    setReady(true);
  }, [name]);
  const update = useCallback(
    (v: string) => {
      setValue(v);
      const params = new URLSearchParams(window.location.search);
      if (v) params.set(name, v);
      else params.delete(name);
      const qs = params.toString();
      window.history.replaceState(null, "", `${window.location.pathname}${qs ? `?${qs}` : ""}`);
    },
    [name],
  );
  return [value, update, ready];
}
