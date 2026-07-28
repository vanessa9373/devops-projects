# CI/CD Pipeline Automation — Implementation Guide

A copy-paste-ready walkthrough for standing this project up against a real AWS account, from an
empty account to a working pipeline that deploys on every push to `main`.

> For architecture, design decisions, and cost breakdown, see [README.md](README.md) and
> [docs/architecture-deep-dive.md](docs/architecture-deep-dive.md). This guide is the "how do I
> actually run this" companion.

---

## Prerequisites

```bash
aws --version          # 2.x
terraform --version    # >= 1.6
node --version          # v20.x
docker --version        # 24+  (only needed to build/test the image locally)
gh --version              # 2.x, and `gh auth status` already logged in

aws sts get-caller-identity
# Confirms your AWS credentials work. Note the "Account" value — you'll need
# it below. Export it for convenience:
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-east-1
echo "$AWS_ACCOUNT_ID / $AWS_REGION"
```

---

## Step 1: Remote state backend (S3 + DynamoDB)

`terraform/main.tf` points at an S3 backend (`vanessa-terraform-state`) and a DynamoDB lock
table (`terraform-state-lock`). These are **account-wide** — if you've already provisioned
another project in this same AWS account (or plan to also deploy the other two projects in
this repo), you only need to create them once.

```bash
# Check if they already exist first
aws s3api head-bucket --bucket vanessa-terraform-state 2>&1 || echo "bucket does not exist yet"
aws dynamodb describe-table --table-name terraform-state-lock >/dev/null 2>&1 || echo "table does not exist yet"
```

If either is missing:

```bash
aws s3api create-bucket \
  --bucket vanessa-terraform-state \
  --region "$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket vanessa-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket vanessa-terraform-state \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

---

## Step 2: GitHub OIDC — let Actions assume an AWS role with no stored keys

### 2a. Register GitHub's OIDC provider (once per AWS account)

```bash
aws iam list-open-id-connect-providers | grep -q token.actions.githubusercontent.com \
  && echo "OIDC provider already registered" \
  || aws iam create-open-id-connect-provider \
       --url https://token.actions.githubusercontent.com \
       --client-id-list sts.amazonaws.com \
       --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea
```

### 2b. Create the deploy role, trusted only by this repo

```bash
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:vanessa9373/devops-projects:*" }
    }
  }]
}
EOF

aws iam create-role \
  --role-name cicd-pipeline-automation-deploy \
  --assume-role-policy-document file:///tmp/trust-policy.json
```

### 2c. Attach exactly the permissions the pipeline needs — nothing more

```bash
cat > /tmp/deploy-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/cicd-pipeline-dev-app"
    },
    {
      "Sid": "EcsDeploy",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EcsService",
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService",
        "ecs:DescribeServices"
      ],
      "Resource": "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:service/cicd-pipeline-dev-cluster/cicd-pipeline-dev-service"
    },
    {
      "Sid": "PassEcsRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/cicd-pipeline-dev-execution-role",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/cicd-pipeline-dev-task-role"
      ],
      "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name cicd-pipeline-automation-deploy \
  --policy-name deploy-permissions \
  --policy-document file:///tmp/deploy-policy.json

aws iam get-role --role-name cicd-pipeline-automation-deploy --query Role.Arn --output text
# Save this ARN — you'll paste it into a GitHub secret in Step 4.
```

---

## Step 3: Provision the infrastructure

```bash
cd terraform
terraform init
terraform plan     # review: ECR repo, ECS cluster/service, ALB, IAM roles, CloudWatch log group
terraform apply
```

Expected: ~15 resources created, finishing with outputs including `alb_dns_name` and
`ecr_repository_url`.

```bash
terraform output alb_dns_name
# e.g. cicd-pipeline-dev-alb-123456789.us-east-1.elb.amazonaws.com
```

The ECS service will show 2 tasks stuck in `PENDING`/failing briefly — that's expected. There's
no image in ECR yet (the task definition's `image_tag` defaults to `"latest"`, which doesn't
exist). That gets fixed by the first real pipeline run in Step 5.

---

## Step 4: Configure the GitHub repo

```bash
cd ..   # back to cicd-pipeline-automation/

gh secret set AWS_DEPLOY_ROLE_ARN --body "arn:aws:iam::${AWS_ACCOUNT_ID}:role/cicd-pipeline-automation-deploy"

gh variable set ALB_DNS_NAME --body "$(cd terraform && terraform output -raw alb_dns_name)"

# Confirm
gh secret list
gh variable list
```

---

## Step 5: Trigger the pipeline

```bash
git commit --allow-empty -m "Trigger first deploy"
git push origin main

gh run watch
# Watch: test -> build-and-push -> deploy -> smoke-test, all green
```

If `deploy` fails immediately on the first run with "service cicd-pipeline-dev-service is
inactive/draining" — re-run it (`gh run rerun`); this can happen if the very first `terraform
apply` and the very first pipeline run raced each other.

---

## Step 6: Verify it's actually running

```bash
ALB=$(cd terraform && terraform output -raw alb_dns_name)

curl "http://$ALB/health"
# {"status":"healthy","uptimeSeconds":...}

curl "http://$ALB/version"
# {"gitSha":"<the commit you just pushed>","buildTime":"..."}

curl "http://$ALB/api/widgets"
# [{"id":1,"name":"Sample Widget","inStock":true}]
```

---

## Step 7: Exercise the rollback path

```bash
# Manual rollback via GitHub Actions UI-equivalent
gh workflow run rollback.yml
gh run watch

# Or locally
./scripts/rollback.sh cicd-pipeline-dev-app cicd-pipeline-dev-cluster cicd-pipeline-dev-service
```

To see the *automatic* rollback (the ECS deployment circuit breaker) fire instead of the manual
path, intentionally ship a broken revision — e.g. change the Dockerfile's `CMD` to a nonexistent
file, push, and watch `deploy` fail while ECS quietly reverts the service to the last healthy
task definition on its own. Revert the change afterward.

---

## Teardown

```bash
cd terraform
terraform destroy

# Optional: remove the IAM role if you're done with this project entirely
aws iam delete-role-policy --role-name cicd-pipeline-automation-deploy --policy-name deploy-permissions
aws iam delete-role --role-name cicd-pipeline-automation-deploy
```
