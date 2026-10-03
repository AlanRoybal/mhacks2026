import assert from "node:assert/strict";
import { test } from "node:test";
import { hasFreeWindow, isQuietTime, localTime } from "./availability.js";
import { haversineKm, travelMinutes } from "./geo.js";
import { challengeCode, newId } from "./ids.js";
import { formatUsd, hourlyCents, quote } from "./money.js";
import type { Availability } from "./types.js";

test("quote adds a 10% fee in whole cents", () => {
  assert.deepEqual(quote(1500), { bountyCents: 1500, feeCents: 150, totalCents: 1650 });
  assert.deepEqual(quote(1005), { bountyCents: 1005, feeCents: 101, totalCents: 1106 });
  assert.throws(() => quote(15.5));
  assert.throws(() => quote(50));
});

test("hourly rate and formatting", () => {
  assert.equal(hourlyCents(1500, 10), 9000);
  assert.equal(formatUsd(1500), "$15");
  assert.equal(formatUsd(1550), "$15.50");
});

test("ids are 26 chars and sortable by time", () => {
  const a = newId(1_700_000_000_000);
  const b = newId(1_700_000_000_001);
  assert.equal(a.length, 26);
  assert.ok(a < b);
  assert.match(challengeCode(), /^[A-Z0-9]{3}-[A-Z0-9]{3}$/);
});

test("haversine and travel time", () => {
  const annArbor = { lat: 42.2808, lng: -83.743 };
  const detroit = { lat: 42.3314, lng: -83.0458 };
  const km = haversineKm(annArbor, detroit);
  assert.ok(km > 55 && km < 60, `got ${km}`);
  assert.equal(travelMinutes(1), 12);
  assert.equal(travelMinutes(30), 60);
});

const NY = "America/New_York";

test("localTime uses Monday = 0", () => {
  // 2026-10-05 is a Monday. 14:30 UTC = 10:30 in New York (EDT).
  assert.deepEqual(localTime(new Date("2026-10-05T14:30:00Z"), NY), { weekday: 0, hour: 10, minute: 30 });
});

test("hasFreeWindow respects weekly hours and busy blocks", () => {
  // Free only Monday 18:00-20:00 local.
  const weekly = Array.from({ length: 168 }, (_, i) => (i === 18 || i === 19 ? "1" : "0")).join("");
  const av: Availability = { tz: NY, weekly, busy: [], updatedAt: "" };
  const mondayNoon = new Date("2026-10-05T16:00:00Z");
  const tuesday = new Date("2026-10-06T16:00:00Z");
  assert.equal(hasFreeWindow(av, mondayNoon, tuesday, 120), true);
  assert.equal(hasFreeWindow(av, mondayNoon, tuesday, 135), false);
  const busy = { ...av, busy: [{ start: "2026-10-05T22:30:00Z", end: "2026-10-05T23:00:00Z" }] };
  assert.equal(hasFreeWindow(busy, mondayNoon, tuesday, 120), false);
  assert.equal(hasFreeWindow(undefined, mondayNoon, tuesday, 600), true);
});

test("quiet hours wrap past midnight", () => {
  const prefs = { tz: NY, quietHours: { start: "22:00", end: "07:00" } };
  assert.equal(isQuietTime(prefs, new Date("2026-10-06T03:00:00Z")), true); // 23:00 local
  assert.equal(isQuietTime(prefs, new Date("2026-10-06T10:00:00Z")), true); // 06:00 local
  assert.equal(isQuietTime(prefs, new Date("2026-10-06T16:00:00Z")), false); // 12:00 local
  assert.equal(isQuietTime({ tz: NY }, new Date()), false);
});
