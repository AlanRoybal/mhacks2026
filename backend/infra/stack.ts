// One stack per stage: `npx cdk deploy -c stage=<name>`. Each teammate can have their own.
//
//   API Gateway (HTTP API) -> api Lambda (Hono app, every route)
//   DynamoDB: jobs, users, offers, proofs, ledger (stream), kv
//   ledger stream -> worker Lambda (runs effects; failures retry, then land in a DLQ)
//   EventBridge Scheduler one-shot timers -> worker Lambda
//   EventBridge rule every minute -> worker Lambda { kind: "sweep" }
//   S3 bucket for uploads (presigned PUT/GET only)

import * as cdk from "aws-cdk-lib";
import { aws_apigatewayv2 as apigw, aws_cloudwatch as cloudwatch, aws_dynamodb as dynamodb, aws_events as events, aws_iam as iam, aws_lambda as lambda, aws_s3 as s3, aws_scheduler as scheduler, aws_sqs as sqs } from "aws-cdk-lib";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import { LambdaFunction } from "aws-cdk-lib/aws-events-targets";
import { DynamoEventSource, SqsDlq } from "aws-cdk-lib/aws-lambda-event-sources";
import { NodejsFunction, OutputFormat } from "aws-cdk-lib/aws-lambda-nodejs";
import type { Construct } from "constructs";
import { fileURLToPath } from "node:url";

// Settings passed through from the deployer's environment (.env). Secrets end up as Lambda environment
// variables, which is fine for a hackathon; move them to Secrets Manager before real users.
const PASSTHROUGH = [
  "DEMO_MODE",
  "DEMO_LOGIN_KEY",
  "JWT_SECRET",
  "AI_PROVIDER",
  "AI_MODEL",
  "ANTHROPIC_API_KEY",
  "EMBED_PROVIDER",
  "PAYMENTS_PROVIDER",
  "STRIPE_SECRET_KEY",
  "STRIPE_PUBLISHABLE_KEY",
  "STRIPE_WEBHOOK_SECRET",
  "PUSH_PROVIDER",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_KEY_P8",
  "APPLE_BUNDLE_ID",
  "APP_URL_SCHEME",
  "LINKEDIN_CLIENT_ID",
  "LINKEDIN_CLIENT_SECRET",
  "ADMIN_USER_IDS",
] as const;

const entry = (file: string) => fileURLToPath(new URL(`../src/handlers/${file}`, import.meta.url));

export class BountyStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps & { stage: string }) {
    super(scope, id, props);
    const { stage } = props;
    const removalPolicy = stage === "prod" ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;
    const name = (suffix: string) => `bounty-${stage}-${suffix}`;

    const table = (suffix: string, partitionKey: dynamodb.Attribute, extra: Partial<dynamodb.TableProps> = {}) =>
      new dynamodb.Table(this, `${suffix}Table`, {
        tableName: name(suffix),
        partitionKey,
        billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
        pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: stage === "prod" },
        removalPolicy,
        ...extra,
      });
    const S = (n: string) => ({ name: n, type: dynamodb.AttributeType.STRING });
    const N = (n: string) => ({ name: n, type: dynamodb.AttributeType.NUMBER });

    const jobs = table("jobs", S("jobId"));
    jobs.addGlobalSecondaryIndex({ indexName: "byPoster", partitionKey: S("posterId"), sortKey: S("createdAt") });
    jobs.addGlobalSecondaryIndex({ indexName: "byWorker", partitionKey: S("workerId"), sortKey: S("updatedAt") });
    const users = table("users", S("userId"));
    const offers = table("offers", S("offerId"));
    offers.addGlobalSecondaryIndex({ indexName: "byJob", partitionKey: S("jobId"), sortKey: S("createdAt") });
    offers.addGlobalSecondaryIndex({ indexName: "byWorker", partitionKey: S("workerId"), sortKey: S("createdAt") });
    const proofs = table("proofs", S("jobId"), { sortKey: S("proofId") });
    const ledger = table("ledger", S("jobId"), { sortKey: N("seq"), stream: dynamodb.StreamViewType.NEW_IMAGE });
    const kv = table("kv", S("key"), { timeToLiveAttribute: "expiresAt" });
    const allTables = [jobs, users, offers, proofs, ledger, kv];

    const bucket = new s3.Bucket(this, "Uploads", {
      bucketName: undefined,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy,
      autoDeleteObjects: stage !== "prod",
    });

    const scheduleGroup = new scheduler.CfnScheduleGroup(this, "Timers", { name: name("timers") });
    const workerName = name("worker");
    const workerArn = this.formatArn({ service: "lambda", resource: "function", resourceName: workerName, arnFormat: cdk.ArnFormat.COLON_RESOURCE_NAME });
    const schedulerRole = new iam.Role(this, "SchedulerRole", { assumedBy: new iam.ServicePrincipal("scheduler.amazonaws.com") });
    schedulerRole.addToPolicy(new iam.PolicyStatement({ actions: ["lambda:InvokeFunction"], resources: [workerArn, `${workerArn}:*`] }));

    const environment: Record<string, string> = {
      STAGE: stage,
      STORE: "dynamo",
      EFFECTS_MODE: "stream",
      SCHEDULER: "eventbridge",
      BLOBS: "s3",
      BUCKET: bucket.bucketName,
      SCHEDULER_GROUP: scheduleGroup.name ?? name("timers"),
      SCHEDULER_ROLE_ARN: schedulerRole.roleArn,
      WORKER_FUNCTION_ARN: workerArn,
      NODE_OPTIONS: "--enable-source-maps",
    };
    for (const key of PASSTHROUGH) {
      const value = process.env[key];
      if (value) environment[key] = value;
    }

    const common = {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 1024,
      environment,
      bundling: {
        format: OutputFormat.ESM,
        target: "node22",
        minify: true,
        sourceMap: true,
        mainFields: ["module", "main"],
        // Some dependencies still call require(); give ESM bundles a working one.
        banner: "import { createRequire as __cr } from 'module'; const require = __cr(import.meta.url);",
      },
    };

    const worker = new NodejsFunction(this, "Worker", { ...common, functionName: workerName, entry: entry("worker.ts"), timeout: cdk.Duration.minutes(5) });
    const api = new NodejsFunction(this, "Api", { ...common, entry: entry("api.ts"), timeout: cdk.Duration.seconds(29) });

    for (const fn of [api, worker]) {
      for (const t of allTables) t.grantReadWriteData(fn);
      bucket.grantReadWrite(fn);
      fn.addToRolePolicy(new iam.PolicyStatement({ actions: ["scheduler:CreateSchedule"], resources: [`arn:${this.partition}:scheduler:${this.region}:${this.account}:schedule/${name("timers")}/*`] }));
      fn.addToRolePolicy(new iam.PolicyStatement({ actions: ["iam:PassRole"], resources: [schedulerRole.roleArn] }));
      // Claude through the Bedrock Mantle endpoint, and Titan embeddings.
      fn.addToRolePolicy(new iam.PolicyStatement({ actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock-mantle:*"], resources: ["*"] }));
    }
    // The API starts background tasks (résumé import) by invoking the worker asynchronously.
    api.addToRolePolicy(new iam.PolicyStatement({ actions: ["lambda:InvokeFunction"], resources: [workerArn] }));

    // Outbox: every new ledger row's effects. One record at a time per shard keeps each job's effects in order.
    const deadLetters = new sqs.Queue(this, "EffectsDlq", { retentionPeriod: cdk.Duration.days(14) });
    worker.addEventSource(
      new DynamoEventSource(ledger, {
        startingPosition: lambda.StartingPosition.LATEST,
        batchSize: 10,
        retryAttempts: 8,
        reportBatchItemFailures: true,
        // Split a failing batch so one bad record can't send healthy ones to the DLQ with it.
        bisectBatchOnError: true,
        onFailure: new SqsDlq(deadLetters),
        filters: [lambda.FilterCriteria.filter({ eventName: lambda.FilterRule.isEqual("INSERT") })],
      }),
    );

    new events.Rule(this, "Sweep", {
      schedule: events.Schedule.rate(cdk.Duration.minutes(1)),
      targets: [new LambdaFunction(worker, { event: events.RuleTargetInput.fromObject({ kind: "sweep" }) })],
    });

    // "Money is stuck" pager: anything in the DLQ means an effect failed every retry.
    new cloudwatch.Alarm(this, "EffectsDlqAlarm", {
      metric: deadLetters.metricApproximateNumberOfMessagesVisible(),
      threshold: 1,
      evaluationPeriods: 1,
      alarmDescription: "A job effect (payout, refund, push, timer, grade) failed every retry",
    });

    const httpApi = new apigw.HttpApi(this, "Http", {
      apiName: name("api"),
      defaultIntegration: new HttpLambdaIntegration("ApiIntegration", api),
    });
    // The API builds absolute URLs (OAuth redirects, file links) from its own address.
    api.addEnvironment("PUBLIC_BASE_URL", process.env.PUBLIC_BASE_URL ?? httpApi.apiEndpoint);
    worker.addEnvironment("PUBLIC_BASE_URL", process.env.PUBLIC_BASE_URL ?? httpApi.apiEndpoint);

    new cdk.CfnOutput(this, "ApiUrl", { value: httpApi.apiEndpoint });
    new cdk.CfnOutput(this, "StripeWebhookUrl", { value: `${httpApi.apiEndpoint}/webhooks/stripe` });
    new cdk.CfnOutput(this, "LinkedInRedirectUrl", { value: `${httpApi.apiEndpoint}/auth/linkedin/callback` });
    new cdk.CfnOutput(this, "EffectsDlqUrl", { value: deadLetters.queueUrl });
  }
}
