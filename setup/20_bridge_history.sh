#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 20: transfer history on "Send to another network"
#
# What this adds:
#   - a "Recent transfers" list under the form on the bridge page (last 20),
#     like "Recent swaps" on the Swap page
#   - each line shows amount, networks, date, recipient and status, and opens
#     the full transfer page with every step
#   - refreshes every 10 seconds while a transfer is still moving
#   Website only: no database or backend changes.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/20_bridge_history.sh
# =============================================================================
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }

step "Checking the project"
[[ -f frontend/src/app/bridge/page.tsx && -f backend/src/swap/service.ts ]] || fail "Run this from ~/dataonchain after script 19 (swaps)"
if [[ -n "$(git status --porcelain | grep -v 'setup/20_bridge_history.sh' || true)" ]]; then
  git status --short
  fail "There are uncommitted changes (listed above). Tell Claude before going on."
fi
git pull -q || fail "git pull failed"
if grep -q "Recent transfers" frontend/src/app/bridge/page.tsx; then
  yellow "The history list is already there. Nothing to do."
  exit 0
fi
green "OK"

step "Adding the transfer history"
git apply --whitespace=nowarn <<'PATCH_END' || fail "Could not apply the change (the bridge page differs from what Claude expected). Nothing was changed."
diff --git a/frontend/src/app/bridge/page.tsx b/frontend/src/app/bridge/page.tsx
index 7dbdd8d..d1546e3 100644
--- a/frontend/src/app/bridge/page.tsx
+++ b/frontend/src/app/bridge/page.tsx
@@ -5,7 +5,8 @@ import { useRouter } from "next/navigation";
 import { useEffect, useState, type FormEvent } from "react";
 import { api } from "@/lib/api";
 import { authClient } from "@/lib/auth-client";
-import { shortAddress, type BridgeQuote, type BridgeView, type Destination } from "@/lib/bridge";
+import { BRIDGE_DONE, BRIDGE_LABELS, shortAddress, type BridgeListItem, type BridgeQuote, type BridgeView, type Destination } from "@/lib/bridge";
+import { toneClass } from "@/lib/orders";
 
 type Limits = { min: number; max: number; daily: number };
 
@@ -19,6 +20,7 @@ export default function BridgePage() {
   const [quote, setQuote] = useState<BridgeQuote | null>(null);
   const [error, setError] = useState<string | null>(null);
   const [busy, setBusy] = useState(false);
+  const [history, setHistory] = useState<BridgeListItem[]>([]);
 
   useEffect(() => {
     if (!isPending && !session) router.replace("/login");
@@ -38,6 +40,28 @@ export default function BridgePage() {
       });
   }, [session]);
 
+  // Past transfers, refreshed every 10 seconds while any is still moving
+  useEffect(() => {
+    if (!session) return;
+    let stop = false;
+    let timer: ReturnType<typeof setTimeout> | undefined;
+    const load = async () => {
+      try {
+        const r = await api<{ transfers: BridgeListItem[] }>("/bridge/transfers");
+        if (stop) return;
+        setHistory(r.transfers);
+        if (r.transfers.some((t) => !BRIDGE_DONE.includes(t.status))) timer = setTimeout(load, 10_000);
+      } catch {
+        // the list is optional; the form still works
+      }
+    };
+    void load();
+    return () => {
+      stop = true;
+      if (timer) clearTimeout(timer);
+    };
+  }, [session]);
+
   async function getQuote(e: FormEvent) {
     e.preventDefault();
     setBusy(true);
@@ -223,6 +247,32 @@ export default function BridgePage() {
             <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
           ) : null}
         </section>
+
+        {history.length > 0 ? (
+          <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
+            <h2 className="text-sm font-medium text-zinc-500">Recent transfers</h2>
+            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
+              {history.map((t) => {
+                const label = BRIDGE_LABELS[t.status] ?? { text: t.status, tone: "wait" as const };
+                return (
+                  <li key={t.id}>
+                    <Link href={`/bridge/${t.id}`} className="flex flex-wrap items-center justify-between gap-2 py-2.5 hover:opacity-80">
+                      <span className="min-w-0">
+                        <span className="block text-zinc-900 dark:text-zinc-100">
+                          {t.amount} USDC {t.sourceChainLabel} → {t.destinationChainLabel}
+                        </span>
+                        <span className="block text-xs text-zinc-500">
+                          {new Date(t.createdAt).toLocaleString("en-NG")} · <span className="font-mono">{shortAddress(t.recipientAddress)}</span>
+                        </span>
+                      </span>
+                      <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
+                    </Link>
+                  </li>
+                );
+              })}
+            </ul>
+          </section>
+        ) : null}
       </div>
     </main>
   );
diff --git a/frontend/src/lib/bridge.ts b/frontend/src/lib/bridge.ts
index cfb7090..cb75da4 100644
--- a/frontend/src/lib/bridge.ts
+++ b/frontend/src/lib/bridge.ts
@@ -66,3 +66,14 @@ export const STEP_LABELS: Record<string, string> = {
 };
 
 export const shortAddress = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;
+
+export type BridgeListItem = {
+  id: string;
+  direction: "OUT" | "IN";
+  status: string;
+  sourceChainLabel: string;
+  destinationChainLabel: string;
+  recipientAddress: string;
+  amount: string;
+  createdAt: string;
+};
PATCH_END
green "OK"

step "Website: build"
if ! (cd frontend && npm run build); then
  git checkout -- frontend
  fail "The website build failed (details above). The change was undone and nothing was committed."
fi
green "OK"

step "Committing to GitHub"
git add frontend/src/app/bridge/page.tsx frontend/src/lib/bridge.ts setup/20_bridge_history.sh
git commit -q -m "Bridge page: recent transfers list with live status"
git push
green "OK: pushed."

echo
green "Script 20 complete. Vercel publishes the website in about 2 minutes."
echo "  Then open: Dashboard > 'Send to another network' and scroll below the form."
