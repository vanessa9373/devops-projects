# Infrastructure as Code Environment Automation — Implementation Guide

A copy-paste-ready walkthrough for standing up dev, staging, and prod from this repo, from an
empty account to three isolated, running environments.

> For architecture, module design, and cost breakdown, see [README.md](README.md) and
> [docs/architecture-deep-dive.md](docs/architecture-deep-dive.md). This guide is the "how do I
> actually run this" companion.

---

## Prerequisites

```bash
aws --version           # 2.x
terraform --version     # >= 1.5

./scripts/bootstrap.sh
# Checks terraform, aws CLI, and AWS credentials in one shot — fix anything
# it flags before continuing.
```

---

## Step 1: Remote state backend

Same S3 bucket/DynamoDB table pattern as the other two projects in this repo — each
environment gets its own state **key** (`iac-environment-automation/dev/terraform.tfstate`,
`.../staging/...`, `.../prod/...`) inside the same bucket. Skip this if you already created it
for `cicd-pipeline-automation` or `kubernetes-microservices-deployment`.

```bash
aws s3api head-bucket --bucket vanessa-terraform-state 2>&1 || \
  aws s3api create-bucket --bucket vanessa-terraform-state --region us-east-1

aws dynamodb describe-table --table-name terraform-state-lock >/dev/null 2>&1 || \
  aws dynamodb create-table \
    --table-name terraform-state-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
```

---

## Step 2: Validate before touching AWS at all

```bash
./scripts/validate-all.sh
# fmt + validate across all 5 modules and all 3 environments — no AWS
# credentials required for this step (init runs with -backend=false).
```

Expect: `All modules and environments passed fmt + validate.`

---

## Step 3: Deploy dev

```bash
./scripts/deploy-environment.sh dev
```

This runs `terraform init` → `plan` → shows you the plan → asks `Apply this plan to 'dev'?
[y/N]`. Expect ~25 resources (VPC, 4 subnets, 1 NAT gateway, 3 security groups, IAM role/
profile, 1 EC2 instance, 1 RDS instance + subnet group).

RDS takes the longest — expect 5-10 minutes for `aws_db_instance.this` alone.

```bash
cd terraform/environments/dev
terraform output
# app_instance_ids, app_instance_private_ips, db_endpoint, db_master_user_secret_arn
cd -
```

---

## Step 4: Verify dev actually works

**Connect to the EC2 instance** (no SSH key needed — SSM Session Manager only):

```bash
INSTANCE_ID=$(cd terraform/environments/dev && terraform output -json app_instance_ids | jq -r '.[0]')
aws ssm start-session --target "$INSTANCE_ID"

# Once connected, on the instance:
cat /var/log/bootstrap.log | tail -20        # confirm ec2-userdata.sh ran to completion
systemctl status docker                       # should be active
systemctl status amazon-cloudwatch-agent       # should be active
exit
```

**Retrieve the DB password** (never a plaintext Terraform variable — it's in Secrets Manager):

```bash
SECRET_ARN=$(cd terraform/environments/dev && terraform output -raw db_master_user_secret_arn)
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq .
# {"username":"admin","password":"..."}
```

**Confirm the DB is reachable only from the app tier, not the internet** — from your own
machine (should time out, which is the point):

```bash
DB_ENDPOINT=$(cd terraform/environments/dev && terraform output -raw db_endpoint)
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${DB_ENDPOINT%:*}/3306" && echo "REACHABLE (unexpected!)" || echo "unreachable, as expected"
```

**Confirm CloudWatch is receiving logs**:

```bash
aws logs tail /ec2/iac-environment-automation/bootstrap --since 30m
```

---

## Step 5: Deploy staging

```bash
./scripts/deploy-environment.sh staging
```

Same flow, different sizing (`t3.small` × 2, still single NAT gateway). Verify the same way as
Step 4, swapping `environments/dev` for `environments/staging`.

---

## Step 6: Deploy prod

```bash
./scripts/deploy-environment.sh prod
```

Notice the plan: 2 NAT gateways (one per AZ) instead of 1, `db.t3.medium` with `multi_az =
true`, and `deletion_protection = true` on the RDS instance. Expect this apply to take longer
than dev/staging — Multi-AZ RDS provisions a synchronous standby before it reports complete.

---

## Teardown

**dev / staging** — straightforward:

```bash
cd terraform/environments/dev      # or staging
terraform destroy
```

**prod** — `deletion_protection = true` on the RDS instance will make `terraform destroy` fail
outright. You have to deliberately turn protection off first:

```bash
cd terraform/environments/prod

# Edit variables.tf: db_deletion_protection default -> false
# (or override without editing the file: )
terraform apply -var="db_deletion_protection=false"

terraform destroy
```

This two-step requirement is intentional, not a bug to work around differently — it's what
`deletion_protection` is for. A prod database should never be one accidental `terraform
destroy` away from gone.

**NAT gateways and RDS instances are the ongoing cost drivers** in this project — if you're not
actively using an environment, destroy it. There's no "pause" state cheaper than not existing.
