#!/usr/bin/env bash
# Print a fresh presigned HTTPS GET URL for the probe zip in S3.
#
# The bucket blocks public access, so every platform downloads the zip through
# a presigned URL. A presigned URL created from an assumed-role (SSO) session is
# only valid for the lifetime of that session (about an hour): if a deploy or an
# EKS Job fails to download the zip, just re-run the step to mint a new one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

EXPIRES="${EXPIRES:-3600}"
aws s3 presign "s3://${BUCKET}/${KEY}" --region "$REGION" --expires-in "$EXPIRES"
