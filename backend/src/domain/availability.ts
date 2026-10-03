import type { Availability, Prefs } from "./types.js";

const STEP_MINUTES = 15;
const HORIZON_MS = 14 * 24 * 60 * 60 * 1000;
const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatterFor(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", hour: "numeric", minute: "numeric", hourCycle: "h23" });
    formatters.set(tz, f);
  }
  return f;
}

// Weekday (0 = Monday), hour and minute of `t` in time zone `tz`.
export function localTime(t: Date, tz: string): { weekday: number; hour: number; minute: number } {
  const parts = formatterFor(tz).formatToParts(t);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return { weekday: WEEKDAYS.indexOf(get("weekday")), hour: Number(get("hour")), minute: Number(get("minute")) };
}

export function isValidTimeZone(tz: string): boolean {
  try {
    formatterFor(tz);
    return true;
  } catch {
    return false;
  }
}

// Is the 15-minute slot [start, end) free? Slots are grid-aligned, so each lies inside one clock hour.
function isSlotFree(av: Availability, start: number, end: number): boolean {
  if (av.weekly) {
    const { weekday, hour } = localTime(new Date(start), av.tz);
    if (av.weekly[weekday * 24 + hour] !== "1") return false;
  }
  return !av.busy.some((b) => Date.parse(b.start) < end && Date.parse(b.end) > start);
}

// True if there is a continuous free stretch of `minutes` between `from` and `to` (capped at 14 days).
// Workers who never shared availability are treated as always free. Errs on the side of "busy".
export function hasFreeWindow(av: Availability | undefined, from: Date, to: Date, minutes: number): boolean {
  if (!av) return true;
  const step = STEP_MINUTES * 60_000;
  const end = Math.min(to.getTime(), from.getTime() + HORIZON_MS);
  let run = 0;
  for (let t = Math.ceil(from.getTime() / step) * step; t + step <= end; t += step) {
    run = isSlotFree(av, t, t + step) ? run + STEP_MINUTES : 0;
    if (run >= minutes) return true;
  }
  return false;
}

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
}

// Quiet hours may wrap past midnight, e.g. 22:00-07:00.
export function isQuietTime(prefs: Pick<Prefs, "quietHours" | "tz">, now: Date): boolean {
  if (!prefs.quietHours) return false;
  const { hour, minute } = localTime(now, prefs.tz);
  const current = hour * 60 + minute;
  const start = minutesOf(prefs.quietHours.start);
  const end = minutesOf(prefs.quietHours.end);
  if (start === end) return false;
  return start < end ? current >= start && current < end : current >= start || current < end;
}
