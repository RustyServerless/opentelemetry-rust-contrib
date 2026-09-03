#!/usr/bin/env bash
# Step 3: run the probe on the two EKS platforms and copy the output to
# CloudWatch, so all five platforms are auditable in the one log group.
#
# CloudFormation builds the EKS cluster, a managed node group (EC2) and a
# Fargate profile, but cannot apply Kubernetes manifests. This script applies a
# Job to each and ships the pod logs to $LOG_GROUP.
#
# Requires kubectl and a fresh presigned URL (minted automatically).
# Re-runnable: it deletes any prior Jobs first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

PROBE_URL="${PROBE_URL:-$("$DEPLOY_DIR/make-presigned-url.sh")}"

echo "== pointing kubectl at $CLUSTER =="
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
kubectl get nodes

# Renders a Job manifest to $3 for job name $1 in namespace $2.
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
          # EKS Fargate sizes the microVM from pod requests; a small default
          # gets the cargo build OOM-killed, so ask for enough headroom.
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
            # The EKS detector needs the cluster name and region supplied
            # explicitly: the aws:eks:cluster-name instance tag is not exposed
            # to pods by default, and on Fargate IMDS is unreachable entirely.
            - name: AWS_CLUSTER_NAME
              value: "{os.environ['CLUSTER']}"
            - name: AWS_REGION
              value: "{os.environ['REGION']}"
            # k8s.pod.uid / k8s.node.name come from the downward API.
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
  local manifest; manifest="$(mktemp)"
  render_job "$name" "$ns" "$manifest"

  kubectl create namespace "$ns" >/dev/null 2>&1 || true
  kubectl -n "$ns" delete job "$name" --ignore-not-found >/dev/null
  kubectl apply -f "$manifest"

  echo "== waiting for $ns/$name (build+run can take a few minutes) =="
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

# Platform 4: EKS on EC2 (scheduled onto the managed node group namespace).
run_and_ship otel-aws-probe-ec2     default       eks-ec2
# Platform 5: EKS on Fargate (namespace matched by the Fargate profile).
run_and_ship otel-aws-probe-fargate probe-fargate eks-fargate

echo
echo "Done. All five platforms now have streams in $LOG_GROUP."
