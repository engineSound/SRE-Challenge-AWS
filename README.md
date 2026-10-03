# SRE Challenge on AWS

A small Flask app ("the answer to everything") made **reliable** on AWS: built with Terraform, deployed by Argo CD from Git, released through a GitHub Actions pipeline with an approval gate, and measured with an SLI/SLO dashboard and email alerts.

It answers the [AmFam DynamicEnablement SRE challenge](#how-this-answers-the-challenge). Nothing runs locally: everything lives in AWS and this repository.

---

## How this answers the challenge

| The challenge asks | What this repo does | Where |
|---|---|---|
| Infrastructure deployed using IaC | Terraform in three layers: state bucket, persistent identity and secrets, one module per environment (VPC, EKS, nodes, add-ons, access, Argo CD) | `terraform/` |
| Service deployed | Flask app on EKS: 3–5 pods with an autoscaler, a disruption budget, spread across zones, behind a public Network Load Balancer | `k8s/apps/sre-challenge/` |
| Automated deployment pipeline | Test → build multi-arch image → preprod → verify → **human approval** → prod → verify | `.github/workflows/release.yml` |
| Monitoring | Prometheus, Grafana and Alertmanager (kube-prometheus-stack), installed by Argo CD | `k8s/argocd/*/05-monitoring-stack.yaml` |
| SLI/SLO dashboard | SLI from real traffic, **99.95% SLO**, multi-window burn-rate alerts by email, Grafana dashboard | `k8s/platform/monitoring/base/` |
| Is everything automated? | Infrastructure from Terraform, everything in the clusters from Git (GitOps), releases from the pipeline | |
| Do I have security in place? | No stored cloud keys in CI (OIDC), private nodes, secrets in AWS Secrets Manager, read-only CI access to clusters, admin tools not public | [Security](#security) |
| How will this scale? | Horizontal pod autoscaler on CPU; node group with headroom; separate preprod and prod | `k8s/apps/sre-challenge/base/hpa.yaml` |
| How am I notified? | Alertmanager emails on error-budget burn, app down and high latency | `slo-rules.yaml` |
| What is my reliability? | The SLI/SLO dashboard, plus two verification scripts that test behavior, including what must be refused | `scripts/verify-*.sh` |
| How can I improve my reliability? | A prioritized hardening list | [Known limits](#known-limits-and-next-improvements) |

---

## Architecture

```
 developer ──push──► GitHub repo (source of truth)
                        │
                        ├─► GitHub Actions: test → build → push image to GHCR
                        │        → commit image tag for preprod → verify (read-only, OIDC)
                        │        → approval → commit image tag for prod  → verify (read-only, OIDC)
                        │
             reads Git  ▼                                  reads Git
   ┌──────────── preprod (own VPC + EKS) ───┐   ┌──────────── prod (own VPC + EKS) ──────────┐
   │ Argo CD → platform, monitoring, app    │   │ Argo CD → platform, monitoring, app        │
   │ app: internal only                     │   │ app ◄── public NLB ◄── users               │
   └────────────────────────────────────────┘   └────────────────────────────────────────────┘
                 persistent layer (survives teardowns): Secrets Manager · GitHub OIDC role · Terraform state
```

- **Two isolated environments,** preprod and prod. Each has its own VPC (2 availability zones, private worker nodes, 1 NAT gateway), EKS cluster (Kubernetes 1.36, 3 × t3.medium), Argo CD and monitoring stack.
- **Argo CD app of apps:** Terraform installs Argo CD and one root Application per environment. The root creates 7 child Applications, ordered by sync waves:
  1. storage and External Secrets
  2. the vault connection
  3. the monitoring secrets
  4. kube-prometheus-stack
  5. SLO rules and the dashboard
  6. the app
- **Image:** `ghcr.io/enginesound/sre-challenge-aws`, tagged `sha-<commit>`, built for amd64 and arm64.

## Release flow

1. Push to `main`, touching the app, the Dockerfile, the tests or the workflow.
2. **test:** `pytest`.
3. **build-push:** a multi-arch image is pushed to GHCR as `sha-<7>`.
4. **deploy-preprod:** the pipeline commits the new tag to the preprod overlay. Argo CD rolls it out.
5. **verify-preprod:** the pipeline logs in to AWS with OIDC and, with read-only access, waits for the rollout and the in-cluster smoke test (`scripts/ci-wait-release.sh`).
6. **promote-prod:** the job waits for a required reviewer to click **Approve and deploy**. It then commits the prod tag and verifies prod the same way, including the public URL.

Rolling updates use `maxSurge: 1, maxUnavailable: 0`, so a new pod must be Ready before an old one stops. A bad release stalls instead of taking users down. To roll back, `git revert` the release commit.

## Monitoring and the SLO

- **SLI:** the share of real user requests that don't return 5xx. Health checks and metric scrapes are excluded.
- **SLO:** **99.95%** over 30 days, which gives an error budget of 0.05%.
- **Alerts:** a fast burn (14.4× over 1 h and 5 min), a slow burn, app down, and high p99 latency. They're delivered by email through Alertmanager.
- **Dashboard:** "SLI/SLO" in Grafana. It's loaded from Git, not edited by hand.
- **Access:** Grafana, Prometheus and Argo CD are not public. Reach them with `kubectl port-forward`.

## Security

- **CI has no AWS keys.** GitHub's OIDC token is exchanged for a role trusted only for this repository's permanent IDs and its `preprod` and `prod` environments. That role can only describe the clusters; inside Kubernetes it is read-only.
- **CI never writes to a cluster.** It commits to Git, and Argo CD applies.
- **Secrets live in AWS Secrets Manager.** External Secrets copies them into the cluster using EKS Pod Identity. Each environment can read only its own secrets plus a shared one, and the verify scripts prove the other environment's secrets are refused.
- **Private nodes.** Only the app's load balancer is public. The Kubernetes API requires an AWS login (anonymous requests get 401).
- **No secret values in this repository.** Git holds only secret names.

## Repository layout

```
app.py, app/            Flask app (/, /health, /version, /metrics)
tests/                  pytest
Dockerfile              python:3.11-slim, gunicorn, health check
.github/workflows/      release pipeline
terraform/
  bootstrap/            S3 state bucket (local state)
  persistent/           GitHub OIDC provider + CI role, Secrets Manager entries
  modules/environment/  VPC, EKS, nodes, add-ons, access entries, Pod Identity, Argo CD
  envs/prod, envs/preprod
k8s/
  argocd/<env>/         the 7 Applications (app of apps), with sync waves
  platform/             storage class, secret store, monitoring rules + dashboard
  apps/sre-challenge/   Kustomize base + preprod/prod overlays
scripts/
  verify-env.sh         19 checks: nodes, DNS, network paths, access (incl. denials), storage, drift
  verify-platform.sh    20 checks: Argo CD, secrets (incl. denial), scraping, SLO rules, email, Grafana, nothing else public
  ci-wait-release.sh    read-only release wait used by the pipeline
  smtp_test.py          sends a test email with the SMTP login from Secrets Manager
```

## Build it yourself

Prerequisites: an AWS account and an IAM user with admin rights for Terraform; AWS CLI, Terraform ≥ 1.10, kubectl, gh.

1. **State bucket:** `cd terraform/bootstrap && terraform init && terraform apply`. Put the bucket name in each layer's backend block.
2. **Persistent layer:** `cd terraform/persistent && terraform apply`. In a fork, first set `github_repo` and `github_oidc_subject_prefix` (find yours with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`).
3. **Alert email login:** put an SMTP login into the empty secret `sre-challenge/shared/alertmanager-smtp`, as JSON with the keys `username`, `password` and `to`. Use `aws secretsmanager put-secret-value`, and never commit it.
4. **An environment:** in `terraform/envs/prod`, set `admin_user_name` to your IAM user and `git_repo_url` to your repo. Then `terraform plan -out=tfplan && terraform apply tfplan`. This takes about 15 minutes; Argo CD then installs the platform within a few minutes.
5. **Verify:** `aws eks update-kubeconfig --name sre-challenge-prod --region us-east-1 --alias sre-challenge-prod`. The scripts expect that context name. Then run `./scripts/verify-env.sh prod` and `./scripts/verify-platform.sh prod`.
6. **Pipeline:** in GitHub, set up:
   - Environments `preprod` and `prod`, with yourself as required reviewer on `prod`.
   - A secret `AWS_CI_ROLE_ARN`, from the persistent layer's output.
   - A variable `PREPROD_ENABLED=true`.
   - Under the GHCR package's Manage Actions access, give this repository **Write**.

**Cost:** roughly $6–7 per day per running environment, mostly EKS, nodes and the NAT gateway.

**Teardown:** the app's load balancer and Prometheus's disk are created by Kubernetes, not Terraform. Delete the Argo CD Applications and Prometheus's volume claim first, wait until the load balancer and disk are gone, then run `terraform destroy`. A script for this is planned.

## Known limits and next improvements

These were chosen on purpose for a demo budget, or found by testing:
- **One NAT gateway per environment:** a zone outage in us-east-1a would cut outbound traffic. The improvement is a NAT per zone, or VPC endpoints.
- **Two zones:** a third zone would make losing a zone cost a third of capacity, not two thirds.
- **Alerting can fail silently:** the fix is to send the always-firing Watchdog alert to an outside heartbeat service.
- **Argo CD isn't monitored yet,** and an Application that can't load from Git reports Healthy.
- **No automatic rollback:** the next step would be a canary with Argo Rollouts, gated on the SLI.
- **Terraform runs from a laptop with a long-lived admin key:** the improvements are SSO and Terraform in CI.
- **Metrics live on one EBS disk:** remote storage would let them survive losing a zone.
