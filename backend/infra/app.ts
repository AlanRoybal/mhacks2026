// CDK entry. Reads backend/.env (if present) for secrets and settings, then builds the stage's stack.
import * as cdk from "aws-cdk-lib";
import { BountyStack } from "./stack.js";

try {
  process.loadEnvFile(".env");
} catch {
  // No .env: rely on the shell environment.
}

const app = new cdk.App();
const stage = String(app.node.tryGetContext("stage") ?? process.env.STAGE ?? "dev");
if (stage === "local") throw new Error('"local" is reserved for the laptop server; pick another stage name');

new BountyStack(app, `Bounty-${stage}`, {
  stage,
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION ?? process.env.AWS_REGION ?? "us-east-1" },
});
