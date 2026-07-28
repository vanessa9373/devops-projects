# CI/CD Pipeline Automation — GitHub Actions + Docker + AWS ECS

> **Architect:** Vanessa Awo · AWS Solutions Architect Associate
> **Stack:** GitHub Actions · Docker · Amazon ECS (Fargate) · Amazon ECR · Application Load Balancer · Terraform
> **Status:** IaC-defined ✅ | CI/CD Pipeline ✅ | Automated Rollback ✅ | Unit Tested ✅

---

## Problem Statement

Manual deploys to AWS are slow and error-prone: someone SSHes in, pulls new code, restarts a
process, and hopes nothing breaks — with no consistent way to test the build first, no audit
trail of what shipped when, and no fast path back to the last good version if it does break.

**Goal:** every push to `main` is automatically tested, containerized, pushed to a private
registry, and deployed to AWS with zero manual steps — and a bad deploy rolls itself back
without anyone needing to notice and intervene.

---

## Pipeline Architecture

```
 Developer                GitHub Actions (.github/workflows/deploy.yml)
 +--------+   push to     +-------+     +----------------+     +----------------+     +------------+
 |  git   | ------------> |  test | --> | build-and-push | --> |     deploy     | --> | smoke-test |
 | commit |    main       | (jest)|     | (docker build, |     | (register task |     | (curl ALB  |
 +--------+                +-------+     |  push to ECR   |     |  def, update   |     |  /health)  |
                                          |  via OIDC)     |     |  ECS service)  |     +------------+
                                          +----------------+     +--------+-------+
                                                                          |
                                                                          v
                                                          +--------------------------------+
                                                          |     Amazon ECS (Fargate)        |
                                                          |  ALB --> Target Group --> Tasks  |
                                                          |  desired_count: 2 (autoscaled)   |
                                                          +----------------+-----------------+
                                                                           |
                                              deployment fails health checks?
                                                                           v
                                          +---------------------------------------------------+
                                          | ECS deployment circuit breaker (terraform-defined) |
                                          | automatically rolls the service back to the last   |
                                          | healthy task definition revision — no human needed |
                                          +---------------------------------------------------+

 Manual rollback path (.github/workflows/rollback.yml, workflow_dispatch):
   engineer --> GitHub Actions --> scripts/rollback.sh --> aws ecs update-service --task-definition <family>:<prior revision>
```

Two independent rollback triggers exist, matching the resume line "automated testing and
rollback triggers":
1. **Automatic** — the ECS deployment circuit breaker (`terraform/main.tf`, `aws_ecs_service.app.deployment_circuit_breaker`) detects a deployment that never reaches steady state and rolls back on its own.
2. **Manual/on-demand** — `scripts/rollback.sh`, runnable locally or via the `rollback.yml` GitHub Actions workflow, for regressions that pass health checks but are still bad (e.g. a broken business feature).

---

## App Reference

The deployed app is a minimal Express service that exists to give the pipeline something real
to build, test, containerize, and health-check.

```bash
curl http://<alb-dns-name>/health
# { "status": "healthy", "uptimeSeconds": 134.2 }

curl http://<alb-dns-name>/version
# { "gitSha": "a1b2c3d", "buildTime": "2026-07-27T18:03:11Z" }

curl http://<alb-dns-name>/api/widgets
# [ { "id": 1, "name": "Sample Widget", "inStock": true } ]

curl -X POST http://<alb-dns-name>/api/widgets \
  -H "Content-Type: application/json" \
  -d '{"name": "New Widget"}'
# 201 { "id": 2, "name": "New Widget", "inStock": true }
```

`/version` reports the Git SHA baked into the image at build time (`GIT_SHA` Docker build arg,
set by the pipeline to `github.sha`) — so you can always confirm exactly which commit is
serving traffic on any given task.

---

## Design Decisions

### Why ECS Fargate (not EC2, not Lambda)?
- No servers/AMIs to patch, unlike ECS-on-EC2.
- Long-running, always-warm HTTP service — a better fit than Lambda's per-invocation model for
  this kind of app; no cold starts to manage.
- Trade-off accepted: Fargate has a higher per-vCPU cost than EC2 reserved capacity — acceptable
  here since this is a small, low-traffic service where ops simplicity wins.

### Why immutable ECR tags keyed to Git SHA (not `:latest`)?
- `image_tag_mutability = "IMMUTABLE"` (terraform/main.tf) means once `<sha>` is pushed it can
  never be silently overwritten.
- Every deployed task definition revision points at an exact, permanent image — rollback is
  "point the service at the previous task definition," not "hope the old `:latest` bits are
  still cached somewhere."

### Why the ECS deployment circuit breaker for rollback (not just a manual script)?
- Health-check failures during a deploy are the most common failure mode, and they need to be
  caught in seconds, not whenever an engineer notices a dashboard. `deployment_circuit_breaker { enable = true, rollback = true }` in `terraform/main.tf` handles that automatically.
- `scripts/rollback.sh` and `rollback.yml` cover the failure mode the circuit breaker
  structurally can't — a deploy that's technically healthy but functionally wrong.

### Why GitHub Actions OIDC (not long-lived AWS access keys)?
- OIDC exchanges a short-lived token for temporary STS credentials per workflow run — nothing
  long-lived is stored in GitHub Secrets.
- If a workflow run or the repo is compromised, the blast radius is one run's temporary
  credentials, not a permanent key.

### Why the default VPC (not a dedicated one)?
- This project is scoped to the pipeline mechanics (build → push → deploy → rollback), not
  network design — reusing the account's default VPC/subnets keeps it focused.
- A from-scratch VPC with public/private subnet tiers, NAT gateways, and route tables is the
  subject of a separate project in this repo: `iac-environment-automation`.

---

## Cost Analysis (us-east-1, always-on)

| Resource | Usage | Monthly Cost |
|---|---|---|
| Fargate tasks | 2 × (0.25 vCPU + 0.5 GB), 24/7 | ~$18.00 |
| Application Load Balancer | 1 ALB + light traffic (~1 LCU) | ~$22.30 |
| ECR storage | ~10 images retained (lifecycle policy) | ~$0.10 |
| CloudWatch Logs | ~1 GB/month, 30-day retention | ~$0.50 |
| **Total** | | **~$41/month** |

> Cost lever for a portfolio/demo environment: drop `desired_count` to 1 and `min_count`/`max_count`
> to 1, or tear the ALB down between demos — the ALB, not compute, is the dominant cost here.

---

## Local Development

```bash
cd app
npm install
npm test              # jest --coverage, 7 tests

npm start              # run locally on :3000
curl localhost:3000/health

# Build and run the container exactly as ECS will run it
docker build -t cicd-pipeline-app .
docker run -p 3000:3000 cicd-pipeline-app
```

---

## Deploy

```bash
# One-time: create an IAM role trusted by GitHub's OIDC provider with
# permission to push to ECR and update the ECS service, then store its ARN
# as the AWS_DEPLOY_ROLE_ARN repo secret.

# Provision the infrastructure
cd terraform
terraform init
terraform apply

# Point the pipeline's smoke test at the ALB it just created
gh variable set ALB_DNS_NAME --body "$(terraform output -raw alb_dns_name)"

# Every push to main from here on: test -> build -> push -> deploy -> smoke test
git push origin main
```

### Rolling back
```bash
# Automatic: nothing to do — the ECS circuit breaker handles failed deployments.

# Manual: via GitHub Actions
gh workflow run rollback.yml

# Manual: locally
./scripts/rollback.sh cicd-pipeline-dev-app cicd-pipeline-dev-cluster cicd-pipeline-dev-service
```

---

## Project Structure

```
cicd-pipeline-automation/
├── app/
│   ├── src/
│   │   ├── index.js              # Express app entrypoint
│   │   └── routes/                # health, version, widgets
│   ├── test/                      # jest + supertest
│   ├── Dockerfile                 # multi-stage, non-root, HEALTHCHECK
│   └── package.json
├── terraform/
│   ├── main.tf                    # ECR, ECS (Fargate), ALB, IAM, autoscaling
│   ├── variables.tf
│   └── outputs.tf
├── .github/workflows/
│   ├── deploy.yml                 # test -> build & push -> deploy -> smoke test
│   └── rollback.yml               # workflow_dispatch manual rollback
├── scripts/
│   └── rollback.sh                # roll ECS service back to a prior task def revision
└── docs/
    └── architecture-deep-dive.md
```

---

## Skills Demonstrated

- **CI/CD:** multi-stage GitHub Actions pipeline — test → build → push → deploy → smoke test
- **Containerization:** multi-stage Dockerfile, non-root user, container-level health check
- **Container orchestration:** ECS Fargate service/task definitions, ALB target group health checks, CPU-based autoscaling
- **Deployment safety:** immutable image tags, ECS deployment circuit breaker (automatic rollback), scripted manual rollback
- **IaC:** modular Terraform with S3 remote state + DynamoDB locking, least-privilege IAM roles
- **Security:** GitHub OIDC → AWS (no long-lived credentials), ECR image scanning on push
- **Testing:** Jest/Supertest unit tests gating every deploy

---

*Built by Vanessa Awo | [LinkedIn](https://www.linkedin.com/in/vanessaaw/) | [Portfolio](https://jenellavan.com/)*
