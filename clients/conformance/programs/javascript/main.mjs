import * as dokkit from "../../../javascript/dokkit.js";

const tag = process.argv[2];

class ConformanceError extends Error {
  name = "ConformanceError";
}

dokkit.start({ version: "9.9.9" });
dokkit.beat("conf-beat", 60);
await dokkit.job("conf-job", () => {});
dokkit.check("conf-check", "ok", 1);
dokkit.metric("conf.metric", 5, "n");
dokkit.log("info", "conformance " + tag, { tag, n: 1 });
dokkit.capture(new ConformanceError("x"));
await dokkit.flush();
