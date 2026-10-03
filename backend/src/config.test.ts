import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { test } from "node:test";
import { loadConfig } from "./config.js";

test(".env.example as-is gives a valid local config (empty values count as unset)", () => {
  const env = parseEnv(readFileSync(new URL("../.env.example", import.meta.url), "utf8"));
  const config = loadConfig(env);
  assert.equal(config.STAGE, "local");
  assert.equal(config.AI_MODEL, undefined);
  assert.equal(config.DEMO_LOGIN_KEY, undefined);
  assert.ok(config.JWT_SECRET.length >= 32);
});

test("deployed stages need a JWT secret", () => {
  assert.throws(() => loadConfig({ STAGE: "dev" }), /JWT_SECRET/);
});
