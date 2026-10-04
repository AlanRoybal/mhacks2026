import type { Deps } from "../deps.js";
import type { StatKey } from "../domain/events.js";
import { newId } from "../domain/ids.js";
import type { User, UserStats } from "../domain/types.js";
import { notFound } from "../lib/errors.js";
import { VersionConflictError } from "../store/index.js";

export const DEFAULT_TZ = "America/Detroit";

const emptyStats = (): UserStats => ({
  offersReceived: 0,
  offersAccepted: 0,
  offersDeclined: 0,
  offersExpired: 0,
  jobsCompleted: 0,
  jobsFailed: 0,
  withdrawals: 0,
  ratingSum: 0,
  ratingCount: 0,
  posterRatingSum: 0,
  posterRatingCount: 0,
});

export function newUser(
  input: Pick<User, "displayName"> & Partial<Pick<User, "userId" | "email" | "photoUrl" | "identities" | "seed">>,
  now: Date,
): User {
  const at = now.toISOString();
  return {
    userId: input.userId ?? newId(now.getTime()),
    version: 1,
    displayName: input.displayName,
    email: input.email,
    photoUrl: input.photoUrl,
    identities: input.identities ?? {},
    twin: {
      skills: [],
      summary: "",
      roles: [],
      education: [],
      certifications: [],
      yearsExperience: 0,
      ingest: { status: "idle", sources: [], updatedAt: at },
      updatedAt: at,
    },
    prefs: { minPayCents: 0, maxRadiusKm: 8, blockedCategories: [], remoteOk: true, inPersonOk: true, tz: DEFAULT_TZ },
    devices: [],
    payouts: { stripeTransfersEnabled: false },
    stats: emptyStats(),
    seed: input.seed,
    createdAt: at,
    updatedAt: at,
  };
}

export async function getUserOrThrow(deps: Deps, userId: string): Promise<User> {
  const user = await deps.store.getUser(userId);
  if (!user) throw notFound("User");
  return user;
}

// Read-modify-write with optimistic locking. `mutate` edits the copy in place.
export async function updateUser(deps: Deps, userId: string, mutate: (user: User) => void): Promise<User> {
  for (let attempt = 1; ; attempt++) {
    const user = await getUserOrThrow(deps, userId);
    const next = structuredClone(user);
    mutate(next);
    next.version = user.version + 1;
    next.updatedAt = deps.now().toISOString();
    try {
      await deps.store.saveUser(user.version, next);
      return next;
    } catch (e) {
      if (e instanceof VersionConflictError && attempt < 5) continue;
      throw e;
    }
  }
}

export async function bumpStats(deps: Deps, userId: string, delta: Partial<Record<StatKey, number>>): Promise<void> {
  await updateUser(deps, userId, (user) => {
    for (const [key, amount] of Object.entries(delta) as [StatKey, number][]) user.stats[key] += amount;
  });
}

// Accept rate × completion rate, 0-1. New workers start at 1 so they are not buried.
export function reliability(stats: UserStats): { acceptRate: number; completionRate: number; score: number } {
  const responded = stats.offersAccepted + stats.offersDeclined + stats.offersExpired;
  const acceptRate = responded === 0 ? 1 : stats.offersAccepted / responded;
  const finished = stats.jobsCompleted + stats.jobsFailed + stats.withdrawals;
  const completionRate = finished === 0 ? 1 : stats.jobsCompleted / finished;
  return { acceptRate, completionRate, score: acceptRate * completionRate };
}
