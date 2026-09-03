#!/usr/bin/env bash
# Step 2: zip the self-contained probe project and upload it to S3.
#
# The project (probe-src/) depends on opentelemetry-aws via the git branch
# wip/aws-resource-detectors, so the zip only needs Cargo.toml, Cargo.lock and
# src/. Every platform runs `cargo run`, building against its own libc.
#
# Run this whenever probe-src/ changes. It is safe to run before 1-deploy.sh
# too (the zip must exist before any platform can download it).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SRC_DIR="$DEPLOY_DIR/probe-src"
TMP="$(mktemp -d)"
( cd "$SRC_DIR" && zip -qr "$TMP/otel-aws-probe.zip" Cargo.toml src )
aws s3 cp "$TMP/otel-aws-probe.zip" "s3://${BUCKET}/${KEY}" --region "$REGION"
echo "uploaded s3://${BUCKET}/${KEY}"
