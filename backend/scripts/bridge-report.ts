// Bridge report on demand (read only): stuck transfers, failures, a check of
// every transfer completed in the last 24 hours against Circle Gateway, and
// the USDC held in Gateway for users.
// Run through: bash setup/bridge-report.sh prod   (or dev)
import { formatReport, reconcile } from "../src/bridge/monitor";

reconcile()
  .then((r) => {
    for (const line of formatReport(r)) console.log(line);
    process.exit(r.issues.length ? 2 : 0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
