import type { Deps } from "../deps.js";
import type { Task } from "../tasks/tasks.js";
import { ingestProfile } from "./twin.js";

export async function runTask(deps: Deps, task: Task): Promise<void> {
  switch (task.name) {
    case "ingest_profile":
      await ingestProfile(deps, task);
      return;
  }
}
