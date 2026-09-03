#!/usr/bin/env bash
# Step 6: force a fresh recompilation + run of the probe on all five platforms,
# without touching the infrastructure. Use this after 2-package-and-upload.sh
# has uploaded new source and you want every platform to rebuild it.
#
#   EC2 (bare)     -> `aws ssm run-command` re-runs the download+build+ship
#                     logic on the live instance (needs the SSM Agent, i.e. the
#                     AmazonSSMManagedInstanceCore policy on Ec2Role).
#   ECS on EC2     -> `aws ecs update-service --force-new-deployment` stops the
#   ECS on Fargate    running task and starts a fresh container, which rebuilds.
#   EKS on EC2     -> the Kubernetes Job is deleted and re-applied (same as
#   EKS on Fargate    3-run-eks-probes.sh), rebuilding in a fresh pod.
#
# Every platform downloads the source through a freshly minted presigned URL, so
# make sure the zip in S3 is current (run 2-package-and-upload.sh first).
#
# Pass one or more platform selectors to limit the scope; default is all five:
#   ./6-rerun-probes.sh                       # all platforms
#   ./6-rerun-probes.sh ec2 ecs-fargate       # just those two
# Valid selectors: ec2 ecs-ec2 ecs-fargate eks-ec2 eks-fargate
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ---------------------------------------------------------------------------
# Selection: default to all five platforms, else the ones named on the CLI.
# ---------------------------------------------------------------------------
ALL="ec2 ecs-ec2 ecs-fargate eks-ec2 eks-fargate"
SELECTED="${*:-$ALL}"
want() { [[ " $SELECTED " == *" $1 "* ]]; }

PROBE_URL="${PROBE_URL:-$("$DEPLOY_DIR/make-presigned-url.sh")}"

# ===========================================================================
# Platform 1: bare EC2 -- re-run via SSM.
# ===========================================================================
rerun_ec2() {
  echo "== EC2 (bare): re-running via aws ssm run-command =="

  local iid
  iid=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=otel-aws-probe-ec2" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)

  if [ -z "$iid" ] || [ "$iid" = "None" ]; then
    echo "  !! no running otel-aws-probe-ec2 instance found; skipping EC2." >&2
    return 0
  fi
  echo "  instance: $iid"

  # The remote command mirrors the CFN UserData: download, build, run, and ship
  # the output to a new ec2/<epoch> stream. The toolchain is already installed
  # from the first boot, so we only source cargo's env (falling back to a full
  # rustup install if this is a fresh instance).
  local script
  script=$(cat <<REMOTE
set -uxo pipefail
export HOME=/root
export GROUP="$LOG_GROUP"
export STREAM="ec2/\$(date +%s)"
export REGION="$REGION"
export PROBE_URL='$PROBE_URL'

if [ ! -f "\$HOME/.cargo/env" ]; then
  dnf install -y gcc git python3 unzip tar gzip >/tmp/dnf.log 2>&1 || true
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "\$HOME/.cargo/env"

cd /root
curl -fSL "\$PROBE_URL" -o probe.zip
rm -rf probe && mkdir -p probe && unzip -o probe.zip -d probe
cd probe
RUST_LOG=debug cargo run --release 2>&1 | tee /root/probe-output.log

aws logs create-log-stream --region "\$REGION" \
  --log-group-name "\$GROUP" --log-stream-name "\$STREAM" || true
python3 - /root/probe-output.log <<'PY'
import json,sys,time,subprocess,os
group=os.environ["GROUP"]; stream=os.environ["STREAM"]; region=os.environ["REGION"]
lines=[l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
now=int(time.time()*1000)
events=[{"timestamp":now+i,"message":l[:250000]} for i,l in enumerate(lines)]
for i in range(0,len(events),1000):
    subprocess.run(["aws","logs","put-log-events","--region",region,
      "--log-group-name",group,"--log-stream-name",stream,
      "--log-events",json.dumps(events[i:i+1000])],check=False)
PY
REMOTE
)

  local cmd_id
  cmd_id=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$iid" \
    --document-name "AWS-RunShellScript" \
    --comment "otel-aws-probe forced recompile" \
    --timeout-seconds 3600 \
    --parameters "$(PARAM_SCRIPT="$script" python3 -c 'import json,os; print(json.dumps({"commands":[os.environ["PARAM_SCRIPT"]],"executionTimeout":["3600"]}))')" \
    --query 'Command.CommandId' --output text)
  echo "  ssm command: $cmd_id"

  echo "  waiting for the command to finish (build+run can take a few minutes)..."
  # `ssm wait command-executed` polls until the invocation reaches a terminal
  # state; a non-zero exit just means it did not finish Success, which we report.
  aws ssm wait command-executed --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$iid" 2>/dev/null || true

  local status
  status=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query 'Status' --output text)
  echo "  EC2 command status: $status (output goes to $LOG_GROUP under ec2/*)"
}

# ===========================================================================
# Platforms 2 & 3: ECS -- force a new deployment so a fresh container rebuilds.
# ===========================================================================
# Resolve the CloudFormation-generated service name for a logical resource id.
ecs_service_name() {
  aws cloudformation describe-stack-resource --region "$REGION" \
    --stack-name "$STACK" --logical-resource-id "$1" \
    --query 'StackResourceDetail.PhysicalResourceId' --output text
}

rerun_ecs() {
  local logical="$1" label="$2"
  echo "== $label: forcing a new ECS deployment =="
  local svc
  svc=$(ecs_service_name "$logical" 2>/dev/null || true)
  if [ -z "$svc" ] || [ "$svc" = "None" ]; then
    echo "  !! could not resolve $logical from stack $STACK; skipping." >&2
    return 0
  fi
  # The physical id is the full ARN; ecs update-service accepts the ARN.
  aws ecs update-service --region "$REGION" \
    --cluster "$CLUSTER" --service "$svc" \
    --force-new-deployment >/dev/null
  echo "  $label: new deployment triggered on $svc"
  echo "     (a fresh task will rebuild; output goes to $LOG_GROUP under $label/*)"
}

# ===========================================================================
# Platforms 4 & 5: EKS -- delete + re-apply the Job, then ship its logs.
# This reuses the same render/ship logic as 3-run-eks-probes.sh.
# ===========================================================================
render_job() {
  local name="$1" ns="$2" out="$3"
  PROBE_URL="$PROBE_URL" CLUSTER="$CLUSTER" REGION="$REGION" RUST_IMAGE="$RUST_IMAGE" \
  NAME="$name" NS="$ns" OUT="$out" python3 <<'PY'
import os
tmpl = f"""apiVersion: batch/v1
kind: Job
metadata:
  name: {os.environ['NAME']}
  namespace: {os.environ['NS']}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 7200
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: {os.environ['RUST_IMAGE']}
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -eux
              apt-get update && apt-get install -y unzip
              curl -fSL "$PROBE_URL" -o /tmp/probe.zip
              cd /tmp && unzip -o probe.zip -d probe && cd probe
              RUST_LOG=debug cargo run --release
          env:
            - name: PROBE_URL
              value: "{os.environ['PROBE_URL']}"
            - name: RUST_LOG
              value: "debug"
            - name: AWS_CLUSTER_NAME
              value: "{os.environ['CLUSTER']}"
            - name: AWS_REGION
              value: "{os.environ['REGION']}"
            - name: POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
"""
open(os.environ['OUT'], 'w').write(tmpl)
PY
}

run_and_ship() {
  local name="$1" ns="$2" prefix="$3"
  echo "== $prefix: re-running Kubernetes Job $ns/$name =="
  local manifest; manifest="$(mktemp)"
  render_job "$name" "$ns" "$manifest"

  kubectl create namespace "$ns" >/dev/null 2>&1 || true
  kubectl -n "$ns" delete job "$name" --ignore-not-found >/dev/null
  kubectl apply -f "$manifest"

  echo "  waiting for $ns/$name (build+run can take a few minutes)..."
  kubectl -n "$ns" wait --for=condition=complete "job/$name" --timeout=900s \
    || kubectl -n "$ns" wait --for=condition=failed "job/$name" --timeout=10s || true

  local out stream; out="$(kubectl -n "$ns" logs "job/$name" 2>&1)"; stream="$prefix/$(date +%s)"
  echo "----- $ns/$name output -----"; echo "$out"

  aws logs create-log-stream --region "$REGION" \
    --log-group-name "$LOG_GROUP" --log-stream-name "$stream" 2>/dev/null || true
  OUT="$out" STREAM="$stream" GROUP="$LOG_GROUP" REGION="$REGION" python3 <<'PY'
import json, os, subprocess, time
out, stream = os.environ["OUT"], os.environ["STREAM"]
group, region = os.environ["GROUP"], os.environ["REGION"]
lines = [l for l in out.splitlines() if l.strip()]
now = int(time.time() * 1000)
events = [{"timestamp": now + i, "message": l[:250000]} for i, l in enumerate(lines)]
for i in range(0, len(events), 1000):
    subprocess.run(["aws", "logs", "put-log-events", "--region", region,
                    "--log-group-name", group, "--log-stream-name", stream,
                    "--log-events", json.dumps(events[i:i + 1000])], check=False)
print(f"shipped {len(events)} events to {stream}")
PY
}

eks_kubeconfig_done=0
ensure_eks_kubeconfig() {
  [ "$eks_kubeconfig_done" = 1 ] && return 0
  echo "== pointing kubectl at $CLUSTER =="
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  eks_kubeconfig_done=1
}

# ===========================================================================
# Drive the selected platforms.
# ===========================================================================
want ec2         && rerun_ec2
want ecs-ec2     && rerun_ecs EcsEc2Service     ecs-ec2
want ecs-fargate && rerun_ecs EcsFargateService ecs-fargate

if want eks-ec2 || want eks-fargate; then
  ensure_eks_kubeconfig
  want eks-ec2     && run_and_ship otel-aws-probe-ec2     default       eks-ec2
  want eks-fargate && run_and_ship otel-aws-probe-fargate probe-fargate eks-fargate
fi

echo
echo "Done. Inspect fresh output with ./4-show-logs.sh (optionally a prefix)."
