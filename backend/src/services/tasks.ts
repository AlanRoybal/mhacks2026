import type { Deps } from "../deps.js";
import type { Task } from "../tasks/tasks.js";
import { gradeProof } from "./grading.js";
import { runMatch } from "./matching.js";
import { handleInboundText } from "./thread.js";
import { learnFromRating } from "./trackRecord.js";
import { ingestGmail, ingestProfile } from "./twin.js";

// Each task re-checks the job's state, so a retried or duplicated task is harmless. If one is lost,
// the grading timeout and the sweeper's rematch take over.
export async function runTask(deps: Deps, task: Task): Promise<void> {
  switch (task.name) {
    case "ingest_profile":
      await ingestProfile(deps, task);
      return;
    case "ingest_gmail":
      await ingestGmail(deps, task);
      return;
    case "thread_inbound":
      await handleInboundText(deps, task);
      return;
    case "grade_proof":
      await gradeProof(deps, task.jobId, task.proofId);
      return;
    case "match_job":
      await runMatch(deps, task.jobId);
      return;
    case "learn_rating":
      await learnFromRating(deps, task.jobId);
      return;
  }
}
