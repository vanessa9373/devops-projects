# Architecture Deep Dive — CI/CD Pipeline Automation

This doc covers how the pipeline actually behaves stage by stage, and the mechanics behind
both rollback paths. For the high-level architecture, API reference, and cost breakdown, see
the [README](../README.md).

---

## Pipeline stages

### 1. `test` (every push and PR)
Runs on every push to `main` and every PR against it — including PRs, so a broken build never
even reaches the point of having an image built for it.

```
actions/checkout → actions/setup-node (Node 20, npm cache) → npm ci → npm test
```

`npm test` runs `jest --coverage` against `app/test/*.test.js`. Nothing after this stage runs
unless it's green.

### 2. `build-and-push` (main only)
Gated by `if: github.ref == 'refs/heads/main' && github.event_name == 'push'` — PRs get tested
but never get an image built, so no PR branch can push into the registry.

1. `aws-actions/configure-aws-credentials` exchanges the workflow's OIDC token for short-lived
   STS credentials scoped to `AWS_DEPLOY_ROLE_ARN`.
2. `aws-actions/amazon-ecr-login` authenticates Docker to the account's ECR registry.
3. `docker build` runs against `app/`, passing `GIT_SHA=$github.sha` and `BUILD_TIME` as build
   args — these land in the image as env vars the running app reads back out via `/version`.
4. The image is pushed to ECR tagged **only** with the Git SHA. There is no `:latest` tag — see
   "Why no `:latest`" below.

### 3. `deploy`
1. `aws ecs describe-task-definition` pulls the task definition currently registered under
   `TASK_DEF_FAMILY`.
2. `aws-actions/amazon-ecs-render-task-definition` takes that JSON and swaps in the new image
   URI (`<registry>/<repo>:<sha>`) for the `app` container, leaving every other field (CPU,
   memory, roles, log config, health check) untouched.
3. `aws-actions/amazon-ecs-deploy-task-definition` registers the rendered definition as a new
   revision and calls `UpdateService` to point `cicd-pipeline-dev-service` at it, then blocks
   (`wait-for-service-stability: true`) until ECS reports steady state.

This is where the two possible outcomes diverge — see "Automatic rollback" below.

### 4. `smoke-test`
A plain `curl` loop against `http://$ALB_DNS_NAME/health` (up to 10 attempts, 6s apart). This
step is deliberately dumb — it's not testing correctness (that's `test`'s job), it's confirming
that whatever is running behind the load balancer right now actually answers. `ALB_DNS_NAME` is
a repo variable set once from the `terraform output alb_dns_name` value; if it's unset the step
no-ops instead of failing the whole pipeline on infra that hasn't been provisioned yet.

---

## Rollback mechanics

### Automatic — ECS deployment circuit breaker
Defined entirely in `terraform/main.tf`, on `aws_ecs_service.app`:

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

When `UpdateService` starts a new deployment, ECS tracks whether the new tasks reach a stable,
healthy state (passing both the container-level `healthCheck` and the ALB target group health
check on `/health`). If they don't within ECS's internal failure threshold — crash-looping
tasks, failed health checks, tasks that never register healthy — ECS:

1. Marks the deployment failed.
2. Automatically starts a new deployment back to the **previous** task definition revision.
3. Emits service events (visible via `aws ecs describe-services` or the console) documenting
   the rollback.

From the pipeline's point of view, `wait-for-service-stability: true` in the `deploy` job is
watching the same signal — if the circuit breaker fires, the service never reaches steady state
on the *new* revision, so the deploy step (and the workflow run) fails. **A failed GitHub Actions
run after a deploy step, on this pipeline, generally means "the circuit breaker just rolled
production back for you"** — check ECS service events first before assuming the rollback didn't
happen.

This path requires zero human input and typically resolves in under a minute — it exists for
the most common deploy failure mode (bad build, missing env var, port mismatch) where waiting
for a person to notice would mean extended downtime.

### Manual — `scripts/rollback.sh`
Covers what the circuit breaker structurally cannot: a deployment that passes every health check
but ships a real functional regression (e.g. a business-logic bug, a broken downstream
integration). Nothing about "the container is up and answering `/health`" tells ECS that.

```
scripts/rollback.sh <task-def-family> <ecs-cluster> <ecs-service> [revision]
```

- With no `[revision]`, it reads the service's *currently running* task definition revision via
  `describe-services`, computes `current - 1`, and treats that as the rollback target — i.e. "undo
  the last deploy," which is the common case.
- With an explicit `[revision]`, it jumps straight to that task definition revision — for
  rolling back further than one step, e.g. after two bad deploys in a row.
- Either way, it verifies the target revision exists (`describe-task-definition`) before
  touching the service, then calls `update-service --task-definition <family>:<revision> --force-new-deployment`
  and blocks on `aws ecs wait services-stable`.

`.github/workflows/rollback.yml` wraps this script in a `workflow_dispatch` trigger so a
rollback is a button in the GitHub Actions UI (Actions → Manual Rollback → Run workflow),
optionally with an explicit revision — not something that requires local AWS CLI access or
someone remembering the exact `aws ecs` incantation under pressure.

---

## Why no `:latest` tag

`aws_ecr_repository.app.image_tag_mutability = "IMMUTABLE"` (terraform/main.tf) means ECR
rejects any attempt to push a tag that already exists. Combined with the pipeline only ever
pushing `<git-sha>` tags:

- Every task definition revision is permanently, unambiguously pinned to one image — there is
  no "which bits were actually behind `:latest` when this incident happened" ambiguity during a
  post-mortem.
- Rollback becomes pure metadata — pointing the service at an older task definition revision —
  rather than depending on an older image still existing under a tag that's designed to be
  overwritten.
- The ECR lifecycle policy (keep last 10 images, any tag status) is the only thing that ever
  deletes an image, so a rollback target from a recent deploy is reliably still pullable.

---

## Known limitations / next steps

- HTTP only on the ALB listener (no ACM cert/HTTPS) — fine for a demo, not for anything real.
- `AWS_DEPLOY_ROLE_ARN`'s OIDC trust policy and IAM permissions aren't defined in this repo's
  Terraform (chicken-and-egg: the role needs to exist before the pipeline that deploys the
  Terraform can run) — provision it once, out of band, scoped to exactly `ecr:*` on this repo's
  repository and `ecs:UpdateService`/`RegisterTaskDefinition` on this cluster/service.
- No blue/green or canary deployment strategy — ECS rolling deploy only. A true blue/green swap
  (e.g. via CodeDeploy) would remove the brief window where old and new tasks serve traffic
  simultaneously during a rolling update.
