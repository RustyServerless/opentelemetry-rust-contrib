# otel-aws-probe

Runs the `opentelemetry-aws` **EC2 / ECS / EKS** resource detectors on five
platforms and collects every resource attribute they emit into a single
CloudWatch log group.

| # | Platform        | How it runs                                    | Log stream prefix |
|---|-----------------|------------------------------------------------|-------------------|
| 1 | EC2 (bare)      | instance UserData: cargo build + run           | `ec2/`            |
| 2 | ECS on EC2      | ECS service, EC2 launch type, `awslogs` driver | `ecs-ec2/`        |
| 3 | ECS on Fargate  | ECS service, Fargate, `awslogs` driver         | `ecs-fargate/`    |
| 4 | EKS on EC2      | Kubernetes Job on a managed node group         | `eks-ec2/`        |
| 5 | EKS on Fargate  | Kubernetes Job on a Fargate profile            | `eks-fargate/`    |

- **Region:** `eu-west-1`  · **Log group:** `/otel-aws-probe` (7-day retention)
- **S3 object:** `s3://peu-importe/otel-aws-probe/otel-aws-probe.zip`

## How it works

`probe-src/` is a small Rust binary that builds a `Resource` from each detector
and logs one line per attribute, with `RUST_LOG=debug` so the detectors' own
internal `tracing` events are visible too. It depends on `opentelemetry-aws`
via the **`wip/aws-resource-detectors`** git branch, so every platform builds it
with its own toolchain — no cross-compilation, and the binary always matches the
platform's libc.

Because the `peu-importe` bucket blocks public access, each platform downloads
the source through a **presigned URL** generated at run time.

> ⚠️ A presigned URL minted from an assumed-role (SSO) session is only valid for
> that session (~1 h). If a download fails, just re-run the step — the scripts
> mint a new URL every time.

## Workflow

```bash
./2-package-and-upload.sh   # zip probe-src/ and upload to S3   (run first, and after any source change)
./1-deploy.sh               # create/update the CloudFormation stack
                            #   -> EC2 + both ECS platforms run the probe automatically
./3-run-eks-probes.sh       # apply the two EKS Jobs and ship their logs to CloudWatch
./4-show-logs.sh            # print the attributes every platform produced
                            #   (optionally: ./4-show-logs.sh eks-fargate)
./6-rerun-probes.sh         # force a fresh recompile+run on all five platforms
                            #   (no infra change; run after 2-package-and-upload.sh)
                            #   (optionally limit: ./6-rerun-probes.sh ec2 ecs-fargate)
./9-destroy.sh              # delete the EKS Jobs and the whole stack (S3 object is left in place)
```

To rebuild the probe everywhere after a source change: run
`./2-package-and-upload.sh` then `./6-rerun-probes.sh`. It uses `aws ssm
run-command` on the bare EC2 instance, `ecs update-service
--force-new-deployment` on both ECS services, and delete+re-apply on both EKS
Jobs.

Timing: the stack takes ~15–20 min (the EKS cluster/node group dominate). The
EC2/ECS probes finish a couple of minutes after the stack is up; the EKS Jobs a
couple of minutes after `3-run-eks-probes.sh`.

Configuration lives in `env.sh` (region, stack name, bucket/key, image, …).
Override any value by exporting it before a script, e.g. `REGION=us-east-1
./1-deploy.sh`. `1-deploy.sh` auto-discovers the default VPC and its subnets;
set `VPC_ID` / `SUBNET_IDS` to use others.

## Files

| File                        | Purpose                                             |
|-----------------------------|-----------------------------------------------------|
| `otel-aws-probe.cfn.yaml`   | CloudFormation template (all infra)                 |
| `probe-src/`                | the self-contained Rust probe project               |
| `env.sh`                    | shared config (sourced by every script)             |
| `make-presigned-url.sh`     | print a fresh presigned GET URL for the zip         |
| `1-deploy.sh`               | create/update the stack                             |
| `2-package-and-upload.sh`   | zip `probe-src/` and upload to S3                   |
| `3-run-eks-probes.sh`       | apply the two EKS Jobs + ship logs to CloudWatch    |
| `4-show-logs.sh`            | pretty-print the per-platform attributes            |
| `6-rerun-probes.sh`         | force a recompile+run on all five platforms         |
| `9-destroy.sh`              | tear everything down                                |

(`deploy.sh`, `package-and-upload.sh`, `run-eks-probes.sh` are thin
back-compat shims that exec the numbered scripts.)

## Required tools (for the nix-shell)

The scripts assume these on `PATH`:

- `awscli2`  — all AWS calls
- `kubectl`  — EKS Jobs (step 3) and teardown (step 9)
- `zip`      — packaging (step 2)
- `python3`  — manifest rendering and `PutLogEvents` batching (steps 3–4)
- `bash`, `coreutils`, `gnused`, `gnugrep`, `curl`  — glue

Everything else (the Rust toolchain, `unzip`, `git`) is only needed **on the
target platforms**, which install it themselves at run time — your workstation
does not build the probe.

## Notes on detector behavior (observed on this account)

- **EC2 / ECS-on-EC2** — full `host.*` + `cloud.*` from IMDSv2 (10 EC2 attrs).
  The ECS detector also fills `host.*` from IMDS on the EC2 launch type (its
  documented fallback); ECS-on-EC2 yields 27 ECS attributes.
- **ECS-on-Fargate** — 22 attributes: `aws.ecs.*`, `aws.log.*.arns`,
  `container.*`, `aws.ecs.launchtype=fargate`. No `host.*` (no IMDS on Fargate).
- **EKS (both)** — the detector only asserts `aws_eks` once something ties the
  pod to AWS. On EKS the `aws:eks:cluster-name` instance tag is not exposed to
  pods by default, and on Fargate IMDS is unreachable, so the Jobs set
  `AWS_CLUSTER_NAME` and `AWS_REGION` explicitly (as the detector docs advise).
  You then get `cloud.platform=aws_eks`, `k8s.*`, `cloud.region`, and (where the
  cgroup exposes it) `container.id` — 8 attrs on EC2, 9 on Fargate.
  `host.*`, `cloud.account.id` and `aws.eks.cluster.arn` additionally require
  IMDS reachable from the pod (raise the metadata hop limit) and
  `AWS_ACCOUNT_ID`, which this setup deliberately does not configure.
