// Calls the admin API through this website's /api pass through.
// Changes (POST) carry X-Admin-Request: 1, which the server requires.
// A 401 on any page except the login pages sends the admin to /login.
export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

const PUBLIC_PAGES = ["/login", "/forgot", "/reset"];

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase();
  const res = await fetch(`/api/admin${path}`, {
    ...init,
    method,
    credentials: "same-origin",
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      ...(method !== "GET" ? { "X-Admin-Request": "1" } : {}),
      ...init.headers,
    },
  });
  const body: unknown = await res.json().catch(() => null);
  if (res.status === 401 && typeof window !== "undefined" && !PUBLIC_PAGES.includes(window.location.pathname)) {
    window.location.href = "/login";
  }
  if (!res.ok) {
    const message =
      body && typeof body === "object" && "error" in body
        ? String((body as { error: unknown }).error)
        : `Something went wrong (${res.status}). Please try again.`;
    throw new ApiError(message, res.status);
  }
  return body as T;
}

export function post<T>(path: string, data: unknown = {}): Promise<T> {
  return api<T>(path, { method: "POST", body: JSON.stringify(data) });
}
