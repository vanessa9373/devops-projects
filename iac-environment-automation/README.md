# Infrastructure as Code Environment Automation — Terraform + Bash

> **Architect:** Vanessa Awo · AWS Solutions Architect Associate
> **Stack:** Terraform (modular) · AWS (VPC, EC2, IAM, RDS, Security Groups) · Bash
> **Status:** 3 environments defined ✅ | Reusable modules ✅ | CI-validated ✅

---

## Problem Statement

Standing up a new environment by hand — a VPC, some EC2 instances, an RDS database, the IAM
roles and security groups to connect them — is slow, inconsistent between environments, and
hard to review: there's no diff to look at before someone clicks "Launch Instance" in the
console.

**Goal:** define the environment once as reusable Terraform modules, then stand up dev,
staging, or prod as a thin composition of those modules with environment-appropriate sizing —
so provisioning a new environment is `./scripts/deploy-environment.sh <env>`, not a checklist.

---

## Architecture

```
terraform/modules/                       terraform/environments/
┌────────────────┐                       ┌──────────┐  ┌──────────┐  ┌──────────┐
│ vpc              │◄──────────┬─────────┤   dev    │  │ staging  │  │   prod   │
│ security-groups  │◄──────────┤         │          │  │          │  │          │
│ iam              │◄──────────┤ each env│ 10.0/16  │  │ 10.1/16  │  │ 10.2/16  │
│ ec2              │◄──────────┤ calls   │ 1 NAT GW │  │ 1 NAT GW │  │ NAT/AZ   │
│ rds              │◄──────────┘ every   │ t3.micro │  │ t3.small │  │ t3.medium│
└────────────────┘             module    │ RDS      │  │ RDS      │  │ RDS      │
                                          │ single-AZ│  │ single-AZ│  │ Multi-AZ │
                                          │ own state│  │ own state│  │ own state│
                                          └──────────┘  └──────────┘  └──────────┘
                                                              |
                                                    scripts/deploy-environment.sh <env>
                                                    scripts/validate-all.sh (fmt + validate)
                                                    scripts/ec2-userdata.sh (bootstrap, runs
                                                      on every EC2 instance at first boot)
```

Each environment is its own Terraform root module with its **own S3 state key** — a mistake in
`dev` cannot corrupt `prod`'s state, and `terraform apply` in one environment never touches
another's resources.

---

## Design Decisions

### Why separate state per environment (not one big `terraform.tfvars` with a `workspace`)?
- Terraform workspaces share the same state file structure and the same backend config —
  it's easy to `terraform apply` against the wrong workspace by forgetting to `terraform
  workspace select` first. Fully separate root modules with hardcoded backend keys
  (`environments/dev/provider.tf` vs `environments/prod/provider.tf`) make it structurally
  impossible to point a `dev` apply at `prod`'s state.
- Trade-off accepted: some duplication between `environments/*/main.tf` files — the modules
  themselves stay DRY; only the composition (which modules, with what variables) repeats.

### Why SSM Session Manager instead of SSH keys / a bastion host?
- `modules/iam` attaches `AmazonSSMManagedInstanceCore` to every instance and `modules/ec2`
  never sets `key_name` — there's no SSH key to lose, rotate, or accidentally commit, and no
  bastion host to patch and pay for.
- `modules/security-groups`' SSH ingress rule only gets created at all if
  `allowed_ssh_cidrs` is non-empty (a `dynamic` block) — by default, across all three
  environments, port 22 isn't open anywhere.

### Why RDS with `manage_master_user_password = true` (not a `db_password` variable)?
- AWS generates and stores the master password in Secrets Manager directly — it's never a
  plaintext Terraform variable, never shows up in a `.tfvars` file, and never appears in a
  `terraform plan` diff.

### Why does staging mirror prod's shape but dev doesn't?
- Staging exists to catch problems before prod sees them — it needs prod's topology (multi-
  instance app tier, same module composition) to actually do that job, just sized down
  (`t3.small` vs `t3.medium`, single NAT gateway instead of one per AZ) to control cost.
- Dev is for individual iteration — single instance, cheapest DB class, `skip_final_snapshot =
  true` — optimized to be torn down and rebuilt often, not to mirror prod.

### Why one shared NAT gateway in dev/staging but one per AZ in prod?
- A NAT gateway is ~$33/month. In dev/staging, an AZ outage taking down egress for a few
  hours is an inconvenience; in prod it's an incident. `single_nat_gateway` (modules/vpc) is
  exposed as a variable specifically so this trade-off is a one-line, per-environment decision
  instead of a fork in the module.

---

## Local Development

```bash
./scripts/bootstrap.sh
# Checks terraform, aws CLI, and AWS credentials are all in place

./scripts/validate-all.sh
# fmt + validate across every module and every environment — same check CI runs
```

## Deploy

```bash
./scripts/deploy-environment.sh dev
# terraform init -> plan -> (confirm) -> apply, scoped to environments/dev

./scripts/deploy-environment.sh staging --auto-approve
# Same, but skips the interactive confirmation (for CI/automation use)

./scripts/deploy-environment.sh prod
# Same flow — prod is not structurally different, just a different environments/ directory
# with deletion_protection = true and Multi-AZ RDS
```

---

## Cost Analysis (us-east-1, per environment, always-on)

| | dev | staging | prod |
|---|---|---|---|
| EC2 (app tier) | 1 × t3.micro ≈ $7.60 | 2 × t3.small ≈ $30.40 | 2 × t3.medium ≈ $60.80 |
| NAT Gateway(s) | 1 × ≈ $33 | 1 × ≈ $33 | 2 × ≈ $66 |
| RDS | db.t3.micro, single-AZ ≈ $13 | db.t3.small, single-AZ ≈ $26 | db.t3.medium, Multi-AZ ≈ $122 |
| **Total/month** | **~$54** | **~$89** | **~$249** |

> Biggest lever across all three: `./scripts/deploy-environment.sh <env>` down to zero
> (terraform destroy) when an environment isn't actively being used — dev and staging in
> particular have no reason to run 24/7 for a portfolio project.

---

## Project Structure

```
iac-environment-automation/
├── terraform/
│   ├── modules/
│   │   ├── vpc/                  # VPC, public/private subnets, NAT (1 or per-AZ)
│   │   ├── security-groups/      # web / app / db tiers, least-privilege between them
│   │   ├── iam/                  # EC2 role: SSM + CloudWatch agent, no SSH keys
│   │   ├── ec2/                  # instances, latest AL2023 AMI, IMDSv2 enforced
│   │   └── rds/                  # MySQL, Secrets-Manager-managed password
│   └── environments/
│       ├── dev/                  # 1 instance, single-AZ RDS, cheapest sizing
│       ├── staging/               # prod's shape, staging's sizing
│       └── prod/                  # Multi-AZ RDS, NAT per AZ, deletion protection
├── scripts/
│   ├── bootstrap.sh                 # local tool/credential check
│   ├── deploy-environment.sh          # init -> plan -> apply for one environment
│   ├── validate-all.sh                 # fmt + validate across every module/environment
│   └── ec2-userdata.sh                  # runs on every instance at first boot
├── .github/workflows/
│   └── terraform-ci.yml                  # runs validate-all.sh + shellcheck on every PR
└── docs/
    └── architecture-deep-dive.md
```

---

## Skills Demonstrated

- **IaC:** modular, reusable Terraform (5 modules) composed differently per environment,
  each environment with isolated remote state
- **Multi-environment design:** deliberate, documented sizing/topology differences between
  dev, staging, and prod — not copy-pasted config with find-and-replace
- **Configuration management:** `scripts/ec2-userdata.sh` bootstraps every instance
  identically at boot (CloudWatch agent, Docker, hostname) with no manual post-launch steps
- **Security:** SSM Session Manager instead of SSH keys/bastions, tiered security groups
  (web → app → db, never db from the internet), Secrets-Manager-managed DB credentials,
  IMDSv2 enforced on every instance
- **Testing/documentation:** `scripts/validate-all.sh` runs the identical fmt/validate check
  locally and in CI — "works on my machine" and "passed CI" are guaranteed to mean the same
  thing
- **Version control practice:** environment-specific state keys and clear module/environment
  separation, documented design trade-offs (this README) instead of tribal knowledge

---

*Built by Vanessa Awo | [LinkedIn](https://www.linkedin.com/in/vanessaaw/) | [Portfolio](https://jenellavan.com/)*
