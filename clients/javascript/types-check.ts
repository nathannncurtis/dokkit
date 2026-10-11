// Checked, not run:   npx -p typescript tsc --noEmit --strict --module nodenext types-check.ts
import * as dokkit from "./dokkit.js";

dokkit.start({ version: "2.3.0" });
dokkit.start({ version: "2.3.0", announceVersion: false });
dokkit.beat("worker", 30);
dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
dokkit.metric("queue.depth", 7);
dokkit.log("error", "Upload failed", { file: "a.pdf" });
const purged: Promise<number> = dokkit.job("nightly-purge", async (run) => {
  run.progress(4000, 9000);
  return 9000;
});
dokkit.capture(new Error("x"), { handled: false, tags: { area: "upload" } });
// @ts-expect-error a state Dokkit does not have
dokkit.check("queue-age", "broken");
void purged;
