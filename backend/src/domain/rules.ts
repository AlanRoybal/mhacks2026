// Timing and limits used by the state machine. Demo mode shortens every wait.
export interface Rules {
  offerTtlSec: number;
  // Review window after a passing AI grade. Payment auto-releases when it ends.
  reviewWindowSec: number;
  // Window for the poster to decide on an unclear or repeatedly failed grade. Escalates to a dispute.
  posterDecisionWindowSec: number;
  rematchDelaySec: number;
  maxMatchRounds: number;
  // If grading has not finished by then, the poster decides instead.
  gradeTimeoutSec: number;
  // If no admin resolves a dispute by then, the AI's assessment stands (fail refunds, otherwise release).
  disputeWindowSec: number;
  // Failed gradings a worker may retry after (US-43: "retry up to two times").
  maxRetries: number;
  checkInRadiusM: number;
}

export function rulesFor(demoMode: boolean): Rules {
  return demoMode
    ? {
        offerTtlSec: 30,
        reviewWindowSec: 120,
        posterDecisionWindowSec: 300,
        rematchDelaySec: 60,
        maxMatchRounds: 10,
        gradeTimeoutSec: 180,
        disputeWindowSec: 600,
        maxRetries: 2,
        checkInRadiusM: 500,
      }
    : {
        offerTtlSec: 45,
        reviewWindowSec: 24 * 3600,
        posterDecisionWindowSec: 48 * 3600,
        rematchDelaySec: 600,
        maxMatchRounds: 12,
        gradeTimeoutSec: 15 * 60,
        disputeWindowSec: 72 * 3600,
        maxRetries: 2,
        checkInRadiusM: 200,
      };
}
