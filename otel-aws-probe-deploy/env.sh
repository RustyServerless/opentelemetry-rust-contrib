#!/usr/bin/env bash
# Shared configuration sourced by all otel-aws-probe scripts.
# Override any of these by exporting them before running a script.
export REGION="${REGION:-eu-west-1}"
export STACK="${STACK:-otel-aws-probe}"
export CLUSTER="${CLUSTER:-otel-aws-probe}"
export LOG_GROUP="${LOG_GROUP:-/otel-aws-probe}"
export BUCKET="${BUCKET:-peu-importe}"
export KEY="${KEY:-otel-aws-probe/otel-aws-probe.zip}"
export RUST_IMAGE="${RUST_IMAGE:-rust:1-bookworm}"

# Absolute path to this deploy directory, whatever the caller's cwd.
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR
