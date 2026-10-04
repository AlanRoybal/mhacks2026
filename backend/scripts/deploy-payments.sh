#!/bin/bash
# Deploy payments-server to its EC2 instance behind CloudFront (infra/payments-stack.ts).
#
#   scripts/deploy-payments.sh [stage]      # default stage: dev
#
# 1. Writes the server's settings to the SecureString parameter /bounty/<stage>/payments-server/env, built from
#    payments-server/.env, .env.chain and .env.aws (deploy-only overrides, such as the Stripe dashboard
#    endpoint's webhook secret). HOST, PORT and BOUNTY_PUBLIC_URL are set here. Nothing secret is printed.
# 2. Deploys the BountyPayments-<stage> stack (code upload, instance, CloudFront).
# 3. Runs /opt/bounty/update.sh on the instance through SSM to install the code and restart the service.
set -euo pipefail
stage=${1:-dev}
here=$(cd "$(dirname "$0")/.." && pwd)
payments="$here/../payments-server"
stack="BountyPayments-$stage"
param="/bounty/$stage/payments-server/env"

output() { aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || true; }

put_env() {
  local public_url=$1
  # Later files win: .env.aws overrides .env.chain overrides .env.
  PUBLIC_URL="$public_url" node --input-type=module -e '
    import { existsSync, readFileSync } from "node:fs";
    const dir = process.argv[1];
    const vars = new Map();
    for (const f of [".env", ".env.chain", ".env.aws"]) {
      if (!existsSync(`${dir}/${f}`)) continue;
      for (const line of readFileSync(`${dir}/${f}`, "utf8").split("\n")) {
        const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
        if (m && m[2] !== "") vars.set(m[1], m[2]);
      }
    }
    vars.set("HOST", "0.0.0.0");
    vars.set("PORT", "4242");
    if (process.env.PUBLIC_URL) vars.set("BOUNTY_PUBLIC_URL", process.env.PUBLIC_URL); else vars.delete("BOUNTY_PUBLIC_URL");
    process.stdout.write([...vars].map(([k, v]) => `${k}=${v}`).join("\n") + "\n");
  ' "$payments" > "$tmp"
  aws ssm put-parameter --name "$param" --type SecureString --overwrite --value "file://$tmp" --query Version --output text >/dev/null
  echo "Wrote $param ($(wc -l < "$tmp" | tr -d ' ') settings)"
}

tmp=$(mktemp); chmod 600 "$tmp"; trap 'rm -f "$tmp"' EXIT

url=$(output PaymentsUrl)
put_env "$url"
(cd "$here" && npx cdk deploy -c stage="$stage" "$stack" --require-approval never)
new_url=$(output PaymentsUrl)
if [ "$new_url" != "$url" ]; then put_env "$new_url"; fi

instance=$(output InstanceId)
echo "Waiting for $instance to register with SSM..."
for _ in $(seq 1 60); do
  [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instance" --query 'length(InstanceInformationList)' --output text)" = "1" ] && break
  sleep 5
done
cmd=$(aws ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript --comment "bounty payments-server update" \
  --parameters 'commands=["cloud-init status --wait >/dev/null || true","/opt/bounty/update.sh","sleep 3","systemctl is-active bounty-payments","curl -fsS localhost:4242/health"]' \
  --query Command.CommandId --output text)
aws ssm wait command-executed --command-id "$cmd" --instance-id "$instance" || true
aws ssm get-command-invocation --command-id "$cmd" --instance-id "$instance" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tail -20
echo "payments-server: $new_url"
