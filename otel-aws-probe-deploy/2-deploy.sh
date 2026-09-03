#!/usr/bin/env bash
# Step 1: create (or update) the CloudFormation stack.
#
# Provisions the four EC2/ECS platforms (which run the probe automatically) and
# the EKS infrastructure (cluster + node group + Fargate profile). The two EKS
# *pods* are launched later by 3-run-eks-probes.sh.
#
# Auto-discovers the default VPC and its subnets unless VPC_ID / SUBNET_IDS are
# exported. Generates a fresh presigned URL for the probe zip each run, so make
# sure the zip is already uploaded (run 2-package-and-upload.sh first).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

PROBE_URL="${PROBE_URL:-$("$DEPLOY_DIR/make-presigned-url.sh")}"

echo "region=$REGION"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$DEPLOY_DIR/otel-aws-probe.cfn.yaml" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides "ProbeSourceUrl=$PROBE_URL"

echo
echo "Stack '$STACK' is up. The EC2 and both ECS platforms run the probe now."
echo "Next: ./3-run-eks-probes.sh  (for the two EKS platforms)"
