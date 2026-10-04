// CDK entry. Reads backend/.env (if present) for secrets and settings, then builds the stage's stack.
import * as cdk from "aws-cdk-lib";
import { PaymentsServerStack } from "./payments-stack.js";
import { BountyStack } from "./stack.js";

// .env.aws (optional) holds deploy-only overrides, such as the Stripe dashboard endpoint's webhook secret
// in place of the `stripe listen` one. loadEnvFile never overwrites a variable that is already set, so it wins.
for (const file of [".env.aws", ".env"]) {
  try {
    process.loadEnvFile(file);
  } catch {
    // Missing file: rely on the other one or the shell environment.
  }
}

const app = new cdk.App();
const stage = String(app.node.tryGetContext("stage") ?? process.env.STAGE ?? "dev");
if (stage === "local") throw new Error('"local" is reserved for the laptop server; pick another stage name');

const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION ?? process.env.AWS_REGION ?? "us-east-1" };
new BountyStack(app, `Bounty-${stage}`, { stage, env });
// Deployed separately with scripts/deploy-payments.sh, which also writes its secrets parameter.
new PaymentsServerStack(app, `BountyPayments-${stage}`, { stage, env });
