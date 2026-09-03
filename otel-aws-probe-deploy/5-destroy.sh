#!/usr/bin/env bash
# Step 9: tear everything down.
#
# Deletes the two EKS Jobs (best-effort) and then the CloudFormation stack,
# which removes the NAT gateway, EKS cluster, node group, Fargate profile, ECS
# cluster/services, the EC2 instance, IAM roles and the CloudWatch log group.
#
# The S3 object is intentionally left alone (the bucket is managed by hand).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "== deleting EKS Jobs (best-effort) =="
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1 || true
kubectl -n default       delete job otel-aws-probe-ec2     --ignore-not-found 2>/dev/null || true
kubectl -n probe-fargate delete job otel-aws-probe-fargate --ignore-not-found 2>/dev/null || true

echo "== deleting stack $STACK =="
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Stack '$STACK' deleted. (S3 object s3://${BUCKET}/${KEY} left in place.)"
