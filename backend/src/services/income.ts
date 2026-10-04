// Verified income statements: a snapshot of a worker's paid jobs, built from the escrow ledger, with a
// public verification page (GET /verify/income/:id). A landlord or lender can check the numbers against
// Bounty without an account. Only payouts that actually landed count.

import { randomBytes } from "node:crypto";
import type { Deps } from "../deps.js";
import { newId } from "../domain/ids.js";
import type { User } from "../domain/types.js";
import { referenceUrl, payoutTiming } from "./money.js";
import { reliability } from "./users.js";

export type StatementPeriod = "year" | "90d" | "all";

export interface IncomeStatement {
  id: string;
  workerName: string;
  issuedAt: string;
  period: { kind: StatementPeriod; from: string | null; to: string };
  currency: "USD";
  totalPaid: number;
  jobCount: number;
  months: { month: string; total: number; jobs: number }[];
  jobs: { title: string; paidAt: string; amount: number; rail: string; reference: string | null; referenceUrl: string | null }[];
  stats: { reliability: number; jobsCompleted: number; rating: number | null };
}

const key = (id: string) => `income:${id}`;
const wire = (iso: string) => iso.replace(/\.\d{3}Z$/, "Z");

function periodStart(now: Date, kind: StatementPeriod): Date | null {
  if (kind === "all") return null;
  if (kind === "year") return new Date(Date.UTC(now.getUTCFullYear(), 0, 1));
  return new Date(now.getTime() - 90 * 86_400_000);
}

export async function createIncomeStatement(deps: Deps, user: User, kind: StatementPeriod): Promise<IncomeStatement> {
  const now = deps.now();
  const from = periodStart(now, kind);
  const jobs = (await deps.store.listJobsByWorker(user.userId)).filter((j) => j.state === "RELEASED" && j.payment.transferId && j.currency === "USD");
  const lines: IncomeStatement["jobs"] = [];
  for (const job of jobs) {
    const { paidAt } = payoutTiming(await deps.store.listLedger(job.jobId));
    if (!paidAt || (from && Date.parse(paidAt) < from.getTime())) continue;
    lines.push({ title: job.title, paidAt: wire(paidAt), amount: job.bountyCents / 100, rail: job.rail, reference: job.payment.transferId ?? null, referenceUrl: referenceUrl(deps, job.payment.transferId) });
  }
  lines.sort((a, b) => b.paidAt.localeCompare(a.paidAt));
  const months = new Map<string, { total: number; jobs: number }>();
  for (const line of lines) {
    const month = line.paidAt.slice(0, 7);
    const m = months.get(month) ?? { total: 0, jobs: 0 };
    months.set(month, { total: m.total + line.amount, jobs: m.jobs + 1 });
  }
  const r = reliability(user.stats);
  const statement: IncomeStatement = {
    // Unguessable: the link is the credential for viewing it.
    id: `${newId(now.getTime())}${randomBytes(8).toString("hex")}`,
    workerName: user.displayName,
    issuedAt: wire(now.toISOString()),
    period: { kind, from: from ? wire(from.toISOString()) : null, to: wire(now.toISOString()) },
    currency: "USD",
    totalPaid: Math.round(lines.reduce((sum, l) => sum + l.amount, 0) * 100) / 100,
    jobCount: lines.length,
    months: [...months].map(([month, m]) => ({ month, total: Math.round(m.total * 100) / 100, jobs: m.jobs })).sort((a, b) => b.month.localeCompare(a.month)),
    jobs: lines,
    stats: {
      reliability: r.score,
      jobsCompleted: user.stats.jobsCompleted,
      rating: user.stats.ratingCount > 0 ? Math.round((user.stats.ratingSum / user.stats.ratingCount) * 10) / 10 : null,
    },
  };
  await deps.store.kvPut(key(statement.id), statement);
  return statement;
}

export const getIncomeStatement = (deps: Deps, id: string) =>
  /^[0-9A-Z]{26}[0-9a-f]{16}$/.test(id) ? deps.store.kvGet<IncomeStatement>(key(id)) : Promise.resolve(null);

export const verifyUrl = (deps: Deps, id: string) => `${deps.config.PUBLIC_BASE_URL}/verify/income/${id}`;

const escape = (s: string) => s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);
const usd = (n: number) => n.toLocaleString("en-US", { style: "currency", currency: "USD" });
const day = (iso: string) => new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });

/** The public page a landlord or lender sees when they open the statement's link. */
export function verificationPage(statement: IncomeStatement | null): string {
  const body = statement
    ? `<p class="ok">&#10003; Verified by Bounty</p>
<h1>${escape(statement.workerName)}</h1>
<p class="muted">Income ${statement.period.from ? `from ${day(statement.period.from)} ` : ""}to ${day(statement.period.to)} · issued ${day(statement.issuedAt)}</p>
<div class="total">${usd(statement.totalPaid)}</div>
<p>${statement.jobCount} paid ${statement.jobCount === 1 ? "job" : "jobs"} · reliability ${Math.round(statement.stats.reliability * 100)}%${statement.stats.rating ? ` · rated ${statement.stats.rating}/5` : ""}</p>
<table><tr><th>Paid</th><th>Job</th><th class="r">Amount</th></tr>
${statement.jobs.map((j) => `<tr><td>${day(j.paidAt)}</td><td>${escape(j.title)}</td><td class="r">${usd(j.amount)}</td></tr>`).join("\n")}
</table>
<p class="muted">Every amount here was held in escrow by Bounty and released to the worker after their work was verified. Bounty generated this page from its payment ledger; the worker can't edit it.</p>`
    : `<h1>Statement not found</h1><p class="muted">This link is wrong or the statement was removed. Ask the worker for a new one.</p>`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
<title>Bounty income verification</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 20px;color:#111}h1{margin:.2em 0}.ok{color:#2F7A00;font-weight:600}.muted{color:#6B6B6B;font-size:14px}.total{font-size:44px;font-weight:700;margin:12px 0 4px}table{width:100%;border-collapse:collapse;margin:20px 0}th,td{text-align:left;padding:8px 4px;border-bottom:1px solid #EBEBEB;font-size:14px}.r{text-align:right}</style>
</head><body>${body}</body></html>`;
}
