# Architecture Deep Dive — Infrastructure as Code Environment Automation

For the high-level architecture, cost breakdown, and top-level design decisions, see the
[README](../README.md). This doc covers how the module/environment split actually works, the
security-group tiering, and the testing approach in more detail.

---

## Module composition: what each environment actually assembles

Every `environments/<env>/main.tf` calls the same five modules, in the same order, wired the
same way — only the variable values passed in (from that environment's `variables.tf`
defaults) differ:

```
module.vpc               -> vpc_id, public_subnet_ids, private_subnet_ids
       |
       v
module.security_groups   -> web_sg_id, app_sg_id, db_sg_id     (needs vpc_id)
       |
       v
module.iam                -> instance_profile_name              (no dependency on the above)
       |
       v
module.ec2                -> instance_ids, private_ips
       (needs: private_subnet_ids, app_sg_id, instance_profile_name,
        user_data = the compiled ec2-userdata.sh content)
       |
       v
module.rds                -> db_endpoint, master_user_secret_arn
       (needs: private_subnet_ids, db_sg_id)
```

Nothing in `modules/*` reads `var.environment` or branches on which environment it's being
used from — modules don't know what environment they're in. All environment-specific behavior
(instance size, Multi-AZ, NAT topology) is a variable value chosen in
`environments/<env>/variables.tf`, not a conditional inside a module. This is what makes it
safe to add a fourth environment later: copy an existing `environments/*` directory, change
the `.tfvars`-equivalent defaults and the backend `key`, done — no module code changes.

---

## Security group tiering

```
Internet
   |
   v
 [web-sg]  ingress: 80/443 from 0.0.0.0/0
   |
   | (app-sg only accepts traffic *from* web-sg's security group ID,
   |  not from any CIDR — this is a security-group-to-security-group
   |  reference, so it stays correct even if subnet CIDRs change later)
   v
 [app-sg]  ingress: app_port from web-sg  (+ SSH from allowed_ssh_cidrs, if set)
   |
   | same pattern: db-sg only accepts from app-sg's ID
   v
 [db-sg]   ingress: db_port from app-sg   — nothing else, ever
```

The db tier has no path to the internet and no path from anything except the app tier. Even if
someone made the DB subnet accidentally public, the security group alone still blocks direct
internet access — defense in depth, not reliance on subnet placement being correct.

SSH is off by default in every environment (`allowed_ssh_cidrs = []`) because of the `dynamic
"ingress"` block in `modules/security-groups/main.tf` — the rule literally doesn't get created
unless the list is non-empty. Combined with SSM Session Manager access (`modules/iam`), there's
no operational need to ever set it.

---

## Testing approach

"Testing" for Terraform doesn't mean unit tests against infrastructure — it means catching the
class of error that's cheap to catch before `apply` and expensive after:

1. **`terraform fmt -check`** — catches formatting drift. Not about style preference; a
   consistently formatted diff is one a reviewer can actually read.
2. **`terraform validate`** — catches type errors, missing required arguments, and invalid
   resource configurations *before* AWS ever sees them. Runs with `-backend=false` in both
   `validate-all.sh` and CI, so it needs zero AWS credentials and can't accidentally touch
   real state.
3. **`shellcheck`** on every script in `scripts/` — the bootstrap and deploy scripts are as
   much a part of this project's correctness as the Terraform is; a typo in
   `deploy-environment.sh` that silently no-ops is just as bad as a broken `.tf` file.

What's deliberately **not** automated here: `terraform plan`/`apply` against real AWS in CI.
Running `plan` on every PR requires long-lived or OIDC AWS credentials in the CI environment
and real infrastructure cost even for a plan against some resource types — for a portfolio
project, `fmt`/`validate`/`shellcheck` catch the errors worth catching automatically; `plan`
review happens locally via `scripts/deploy-environment.sh`, which always shows the plan and
asks for confirmation before `apply`.

---

## Known limitations / next steps

- No automated drift detection (e.g. a scheduled `terraform plan` job that alerts if real
  infrastructure has diverged from state) — would be the natural next addition for a
  long-running environment.
- `modules/ec2` always resolves the *latest* AL2023 AMI at apply time — reproducible in the
  sense that re-running `apply` today always gets today's patched AMI, but it also means two
  applies six months apart can select different AMIs for otherwise-identical instances. A
  stricter reproducibility story would pin an AMI ID per environment and bump it deliberately.
- `environments/*/main.tf` files are structurally identical (only variable values differ) —
  genuinely repeated code, accepted as a trade-off for the isolation benefit explained in the
  README rather than collapsed into one more layer of indirection.
