// payments-server/ (Stripe Connect settlements, worker earnings, Base Sepolia escrow) on one small EC2 instance.
// It keeps SQLite on local disk and runs a 10 s recovery loop, so it needs a long-lived process, not Lambda.
//
//   CloudFront (HTTPS) -> Elastic IP :4242 (only CloudFront's origin-facing ranges) -> node server.mjs (systemd)
//
// Secrets never enter this template. The instance reads them at boot from the SecureString parameter
// /bounty/<stage>/payments-server/env, which scripts/deploy-payments.sh writes. Code ships as an S3 asset;
// /opt/bounty/update.sh downloads it, installs it and restarts the service without touching the database.

import * as cdk from "aws-cdk-lib";
import { aws_cloudfront as cloudfront, aws_ec2 as ec2, aws_iam as iam, aws_s3_assets as assets, aws_ssm as ssm } from "aws-cdk-lib";
import { HttpOrigin } from "aws-cdk-lib/aws-cloudfront-origins";
import type { Construct } from "constructs";
import { fileURLToPath } from "node:url";

const NODE_VERSION = "v22.23.3";
const NODE_SHA256 = "a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f";
const PORT = 4242;

export class PaymentsServerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps & { stage: string }) {
    super(scope, id, props);
    const { stage } = props;
    const envParam = `/bounty/${stage}/payments-server/env`;

    const code = new assets.Asset(this, "Code", {
      path: fileURLToPath(new URL("../../payments-server", import.meta.url)),
      // Never ship local secrets, the local database or dev tooling.
      exclude: ["node_modules", "data", ".env", ".env.*", ".stripe", "*.test.mjs", "*smoke-test.mjs", "setup-test-env.mjs", "deploy-escrow.mjs", "webhook-listener.mjs"],
    });
    const codeUrl = new ssm.StringParameter(this, "CodeUrl", { parameterName: `/bounty/${stage}/payments-server/code-url`, stringValue: code.s3ObjectUrl });

    const vpc = ec2.Vpc.fromLookup(this, "Vpc", { isDefault: true });
    const sg = new ec2.SecurityGroup(this, "Sg", { vpc, description: "payments-server: CloudFront only", allowAllOutbound: true });
    const cloudFrontRanges = ec2.PrefixList.fromLookup(this, "CloudFrontRanges", { prefixListName: "com.amazonaws.global.cloudfront.origin-facing" });
    sg.addIngressRule(ec2.Peer.prefixList(cloudFrontRanges.prefixListId), ec2.Port.tcp(PORT), "CloudFront origin-facing");

    const role = new iam.Role(this, "Role", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      // Session Manager instead of SSH.
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore")],
    });
    code.grantRead(role);
    codeUrl.grantRead(role);
    role.addToPolicy(new iam.PolicyStatement({ actions: ["ssm:GetParameter"], resources: [this.formatArn({ service: "ssm", resource: "parameter", resourceName: envParam.slice(1) })] }));

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "set -euxo pipefail",
      "dnf install -y unzip",
      `curl -fsSL -o /tmp/node.tar.xz https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-arm64.tar.xz`,
      `echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c -`,
      "mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && ln -sf /opt/node/bin/node /usr/local/bin/node && ln -sf /opt/node/bin/npm /usr/local/bin/npm",
      "id bounty || useradd --system --home /var/lib/bounty-payments --shell /sbin/nologin bounty",
      "install -d -o bounty -g bounty -m 700 /var/lib/bounty-payments",
      "install -d -m 755 /opt/bounty",
      `cat > /opt/bounty/update.sh <<'EOF'
#!/bin/bash
# Fetch the current code and secrets, install, and restart. The database in /var/lib/bounty-payments is kept.
set -euo pipefail
export AWS_DEFAULT_REGION=${this.region}
url=$(aws ssm get-parameter --name /bounty/${stage}/payments-server/code-url --query Parameter.Value --output text)
umask 077
aws ssm get-parameter --name ${envParam} --with-decryption --query Parameter.Value --output text > /opt/bounty/env.new
chown root:bounty /opt/bounty/env.new && chmod 640 /opt/bounty/env.new && mv /opt/bounty/env.new /opt/bounty/env
rm -rf /opt/bounty/app.new && mkdir -p /opt/bounty/app.new
aws s3 cp "$url" /tmp/payments-server.zip
unzip -q /tmp/payments-server.zip -d /opt/bounty/app.new
cd /opt/bounty/app.new && PATH=/opt/node/bin:$PATH npm ci --omit=dev --no-audit --no-fund
ln -sfn /var/lib/bounty-payments /opt/bounty/app.new/data
chmod -R a+rX /opt/bounty/app.new
rm -rf /opt/bounty/app.old; [ -d /opt/bounty/app ] && mv /opt/bounty/app /opt/bounty/app.old; mv /opt/bounty/app.new /opt/bounty/app
systemctl restart bounty-payments
EOF`,
      "chmod 700 /opt/bounty/update.sh",
      `cat > /etc/systemd/system/bounty-payments.service <<'EOF'
[Unit]
Description=Bounty payments-server
After=network-online.target
Wants=network-online.target

[Service]
User=bounty
WorkingDirectory=/opt/bounty/app
ExecStart=/opt/node/bin/node --env-file=/opt/bounty/env server.mjs
Environment=HOST=0.0.0.0
Environment=PORT=${PORT}
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/bounty-payments

[Install]
WantedBy=multi-user.target
EOF`,
      "systemctl daemon-reload && systemctl enable bounty-payments",
      // The env parameter may not exist yet on the very first deploy; deploy-payments.sh runs update.sh again.
      "/opt/bounty/update.sh || echo 'update.sh failed; run scripts/deploy-payments.sh'",
    );

    const instance = new ec2.Instance(this, "Server", {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T4G, ec2.InstanceSize.MICRO),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
      securityGroup: sg,
      role,
      userData,
      requireImdsv2: true,
      blockDevices: [{ deviceName: "/dev/xvda", volume: ec2.BlockDeviceVolume.ebs(16, { encrypted: true, volumeType: ec2.EbsDeviceVolumeType.GP3 }) }],
    });
    // User data never mentions the code location, so a code change updates only the parameter and never
    // replaces the instance (and its database).
    instance.node.addDependency(codeUrl);

    const ip = new ec2.CfnEIP(this, "Ip", { instanceId: instance.instanceId });
    // CloudFront needs a host name, not an IP. EC2 publishes ec2-1-2-3-4.compute-1.amazonaws.com for the EIP.
    const originHost = cdk.Fn.join("", ["ec2-", cdk.Fn.join("-", cdk.Fn.split(".", ip.attrPublicIp)), this.region === "us-east-1" ? ".compute-1.amazonaws.com" : `.${this.region}.compute.amazonaws.com`]);

    const distribution = new cloudfront.Distribution(this, "Cdn", {
      comment: `bounty-${stage} payments-server`,
      defaultBehavior: {
        origin: new HttpOrigin(originHost, { protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY, httpPort: PORT }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        // Forward auth and Stripe-Signature headers, query strings and bodies unchanged.
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
      },
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
    });

    new cdk.CfnOutput(this, "PaymentsUrl", { value: `https://${distribution.distributionDomainName}` });
    new cdk.CfnOutput(this, "PaymentsWebhookUrl", { value: `https://${distribution.distributionDomainName}/stripe/webhook` });
    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "EnvParameter", { value: envParam });
  }
}
