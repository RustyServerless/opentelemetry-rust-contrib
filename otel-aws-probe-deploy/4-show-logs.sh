#!/usr/bin/env bash
# Step 4: print the resource attributes each platform produced.
#
# Reads the shared CloudWatch log group and, for every stream, shows the
# per-detector attribute lines and the summary counts. Pass a stream prefix
# (ec2, ecs-ec2, ecs-fargate, eks-ec2, eks-fargate) to narrow it down.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

FILTER="${1:-}"
streams=$(aws logs describe-log-streams --region "$REGION" \
  --log-group-name "$LOG_GROUP" --query 'logStreams[].logStreamName' --output text)

for s in $streams; do
  [ -n "$FILTER" ] && [[ "$s" != "$FILTER"* ]] && continue
  echo "==================== $s ===================="
  aws logs get-log-events --region "$REGION" --log-group-name "$LOG_GROUP" \
    --log-stream-name "$s" --limit 10000 --query 'events[].message' --output text \
    | tr '\t' '\n' \
    | grep -oE 'attribute=[^ ]+ value=.*|(EC2|ECS|EKS) detector produced.*attribute_count=[0-9]+' || true
  echo
done
