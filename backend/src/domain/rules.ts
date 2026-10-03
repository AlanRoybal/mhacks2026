// Timing and limits used by the state machine. Demo mode shortens every wait.
export interface Rules {
  offerTtlSec: number;
  // Review window after a passing AI grade. Payment auto-releases when it ends.
  reviewWindowSec: number;
  // Window for the poster to decide on an unclear or repeatedly failed grade. Escalates to a dispute.
  posterDecisionWindowSec: number;
  rematchDelaySec: number;
  maxMatchRounds: number;
  // Failed gradings a worker may retry after (US-43: "retry up to two times").
  maxRetries: number;
  checkInRadiusM: number;
  // Timers may fire a little early; events within this many ms of their due time are accepted.
  timerToleranceMs: number;
}

export function rulesFor(demoMode: boolean): Rules {
  return demoMode
    ? {
        offerTtlSec: 30,
        reviewWindowSec: 120,
        posterDecisionWindowSec: 300,
        rematchDelaySec: 60,
        maxMatchRounds: 10,
        maxRetries: 2,
        checkInRadiusM: 500,
        timerToleranceMs: 2000,
      }
    : {
        offerTtlSec: 45,
        reviewWindowSec: 24 * 3600,
        posterDecisionWindowSec: 48 * 3600,
        rematchDelaySec: 600,
        maxMatchRounds: 12,
        maxRetries: 2,
        checkInRadiusM: 200,
        timerToleranceMs: 2000,
      };
}
