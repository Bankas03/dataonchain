// Calls the backend through the website's /api pass through.
// Errors carry the backend's own message, ready to show to the user.
export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`/api${path}`, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  const body: unknown = await res.json().catch(() => null);
  if (!res.ok) {
    const message =
      body && typeof body === "object" && "error" in body
        ? String((body as { error: unknown }).error)
        : `Something went wrong (${res.status}). Please try again.`;
    throw new Error(message);
  }
  return body as T;
}
