// All amounts are integer cents. The poster pays bounty + fee; the worker receives the bounty.

export const PLATFORM_FEE_BPS = 1000; // 10%
export const MIN_BOUNTY_CENTS = 100;
export const MAX_BOUNTY_CENTS = 100_000;

export interface Quote {
  bountyCents: number;
  feeCents: number;
  totalCents: number;
}

export function quote(bountyCents: number): Quote {
  if (!Number.isInteger(bountyCents)) throw new RangeError("bountyCents must be an integer");
  if (bountyCents < MIN_BOUNTY_CENTS || bountyCents > MAX_BOUNTY_CENTS) {
    throw new RangeError(`bountyCents must be between ${MIN_BOUNTY_CENTS} and ${MAX_BOUNTY_CENTS}`);
  }
  const feeCents = Math.round((bountyCents * PLATFORM_FEE_BPS) / 10_000);
  return { bountyCents, feeCents, totalCents: bountyCents + feeCents };
}

export function hourlyCents(bountyCents: number, minutes: number): number {
  return Math.round((bountyCents * 60) / Math.max(minutes, 1));
}

// "$15" for whole dollars, "$15.50" otherwise.
export function formatUsd(cents: number): string {
  const dollars = cents / 100;
  return Number.isInteger(dollars) ? `$${dollars}` : `$${dollars.toFixed(2)}`;
}
