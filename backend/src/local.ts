// Local dev server: `npm run dev`. In-memory store snapshotted to .data/, effects run in-process.
import { serve } from "@hono/node-server";
import { createApp } from "./api/app.js";
import { getDeps } from "./deps.js";
import { sweep } from "./services/sweeper.js";

const deps = getDeps();
const app = createApp(deps);

// Same backstop as the deployed one-minute sweep.
setInterval(() => {
  sweep(deps).catch((error: unknown) => deps.log.error("Sweep failed", { error }));
}, 30_000).unref();

serve({ fetch: app.fetch, port: deps.config.PORT }, (info) => {
  deps.log.info(`Bounty API listening on http://localhost:${info.port}`, {
    store: deps.config.STORE,
    effects: deps.config.EFFECTS_MODE,
    demoMode: deps.config.DEMO_MODE,
  });
});
