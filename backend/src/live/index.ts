import type { Config } from "../config.js";
import type { Logger } from "../lib/log.js";
import { MemoryLive, type LiveSessions } from "./live.js";
import { SpacetimeLive } from "./spacetime.js";

export function createLive(config: Config, log: Logger, now: () => Date): LiveSessions {
  if (config.LIVE_PROVIDER === "spacetime") {
    if (!config.SPACETIME_TOKEN) throw new Error("LIVE_PROVIDER=spacetime needs SPACETIME_TOKEN (the identity that published bounty-live)");
    return new SpacetimeLive(config.SPACETIME_URL, config.SPACETIME_DB, config.SPACETIME_TOKEN, log);
  }
  return new MemoryLive(now);
}

export * from "./live.js";
