# AWS Organizations SCP Management

End-to-end Terraform workflow to **export** existing Service Control Policies (SCPs) and their current OU attachments, and then **apply**/manage those SCPs across **two AWS Organizations** (e.g., **nonprod** and **prod**) — one org at a time — using the same policy set.

* `modules/scp_audit`: exports SCP JSONs and writes an HCL var file with the mapping of **policy → OUs**.
* `modules/scp_apply`: creates/updates policies from JSON (manage mode) or attaches existing policies (attach-only), and **diffs** current vs desired attachments to avoid duplicates.

No Terraform workspaces required — each org has its own state in separate `envs/<org>` folders.

---

## Table of Contents

* [Prerequisites](#prerequisites)
* [Repo Layout](#repo-layout)
* [Modules Overview](#modules-overview)

  * [scp\_audit (export)](#scp_audit-export)
  * [scp\_apply (apply/manage)](#scp_apply-applymanage)
* [Environment Setup (separate state per org)](#environment-setup-separate-state-per-org)
* [Step-by-Step Workflow](#step-by-step-workflow)

  1. [Export current SCPs and mapping](#1-export-current-scps-and-mapping)
  2. [Apply to NONPROD](#2-apply-to-nonprod)
  3. [Apply to PROD](#3-apply-to-prod)
  4. [Make changes later](#4-make-changes-later)
* [Common Operations](#common-operations)
* [Troubleshooting](#troubleshooting)
* [Permissions & Safety](#permissions--safety)
* [CI/CD Tips](#cicd-tips)

---

## Prerequisites

* **Terraform** ≥ 1.3 (you’re on 1.13.0 — great).
* **AWS provider** ≥ 6.x.
* **AWS CLI** configured profiles for each org’s **management** account (or SSO).
* **Organizations SCPs enabled** in each org.
* **jq** installed (for pretty JSON export in `scp_audit`).

> Minimum IAM for the management account role/user:
>
> * Read/Discover: `organizations:ListPolicies`, `DescribePolicy`, `ListTargetsForPolicy`, `ListRoots`, `ListChildren`, `DescribeOrganization`.
> * Manage policies: `CreatePolicy`, `UpdatePolicy`, `AttachPolicy`, `DetachPolicy`.
> * (Optional) Lock down to `SERVICE_CONTROL_POLICY` type resources.

---

## Repo Layout

```
repo-root/
├── modules/
│   ├── scp_audit/        # EXPORT: reads org, exports policy JSONs, writes scp_ou_map.auto.tfvars (HCL)
│   └── scp_apply/        # APPLY: manage policy content and attach (diffs attachments to avoid duplicates)
├── policies/             # Shared policy files + exported map (recommended target)
│   ├── <PolicyName>.json
│   └── scp_ou_map.auto.tfvars
└── envs/
    ├── nonprod/          # Separate Terraform state for nonprod org
    │   ├── main.tf
    │   └── variables.tf
    └── prod/             # Separate Terraform state for prod org
        ├── main.tf
        └── variables.tf
```

> You can regenerate `policies/*` via `scp_audit` and then **reuse the same files** for both orgs.

---

## Modules Overview

### `scp_audit` (export)

**What it does**

* Discovers all OUs (and optionally root).
* Reads current SCP **attachments** for each OU/root.
* Exports each policy’s JSON into `${var.scp_base_path}/<PolicyName>.json`.
* Writes **HCL** `scp_ou_map.auto.tfvars` like:

```hcl
scp_ou_map = {
  APIGateway    = ["Sandbox"]
  FullAWSAccess = ["Legacy", "Sandbox"]
  targeted      = ["Legacy", "Sandbox"]
}
```

**Key variables**

* `scp_base_path` (default inside module): set to output under repo-level `policies/`, e.g. `-var='scp_base_path=../../policies'`.
* `include_root` (bool): include policies attached at org root.
* `export_all_scps` (bool): export all SCPs (even if not attached).

**Notes**

* JSON files are **pretty-printed** via `jq`.
* `scp_ou_map.auto.tfvars` is **HCL** (not JSON) so Terraform loads it easily.

---

### `scp_apply` (apply/manage)

**What it does**

* Reads your desired mapping `scp_ou_map` (policy → list of OU tokens).
* Supports OU **names**, **OU IDs** (`ou-xxxx-xxxxxxxx`), or `"ROOT"`.
* **Manage mode (default)**: creates/updates SCPs from `policies/<name>.json`.

  * If a policy with the same name **already exists**, import once (see below), then Terraform manages it.
* **Attach-only mode**: set `manage_policies=false` to attach to **existing** policy names without changing JSON.
* **Diffs** current vs desired attachments and **only creates missing** attachments, avoiding `DuplicatePolicyAttachmentException`.

**Key variables**

* `scp_ou_map`: pass via `-var-file=policies/scp_ou_map.auto.tfvars`.
* `scp_base_path`: path to JSON files (e.g., `../../policies` when running from env folder).
* `manage_policies` (default `true`): enable policy creation/updates from files.
* `attachment_skip_destroy` (default `true`): avoids detach on `destroy`.

---

## Environment Setup (separate state per org)

Each environment has its own minimal root configuration that **calls the same module**:

`envs/nonprod/variables.tf` (similar for prod; just change default `profile`)

```hcl
variable "region"  { type = string, default = "us-east-1" }
variable "profile" { type = string, default = "org-nonprod-mgmt" }

variable "manage_policies"         { type = bool,   default = true }
variable "scp_base_path"           { type = string, default = "../../policies" }
variable "scp_ou_map"              { type = map(list(string)), default = {} }
variable "attachment_skip_destroy" { type = bool,   default = true }
```

`envs/nonprod/main.tf` (prod uses `org-prod-mgmt` profile)

```hcl
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
  # (Optional) S3 backend here per env to keep remote state isolated
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

module "apply_scps" {
  source                  = "../../modules/scp_apply"
  manage_policies         = var.manage_policies
  scp_base_path           = var.scp_base_path
  scp_ou_map              = var.scp_ou_map
  attachment_skip_destroy = var.attachment_skip_destroy
}
```

> With this structure, **no workspaces** are needed. Each env folder has its own `terraform.tfstate`. If you prefer remote state, add an S3 backend in each env with a different `key` (e.g., `scp/nonprod.tfstate` vs `scp/prod.tfstate`).

---

## Step-by-Step Workflow

### 1) Export current SCPs and mapping

From `modules/scp_audit/`:

```bash
terraform init
terraform apply -var='scp_base_path=../../policies'
```

Results under repo `policies/`:

* `<PolicyName>.json` (pretty-printed)
* `scp_ou_map.auto.tfvars` (HCL map)

### 2) Apply to NONPROD

From `envs/nonprod/`:

```bash
terraform init
terraform plan  -var-file=../../policies/scp_ou_map.auto.tfvars
terraform apply -var-file=../../policies/scp_ou_map.auto.tfvars
```

* If any policies already exist and you’re in **manage mode**, Terraform will fail fast with **import commands**. Run the imports once (see **Common Operations**) and re-apply.

### 3) Apply to PROD

From `envs/prod/`:

```bash
terraform init
terraform plan  -var-file=../../policies/scp_ou_map.auto.tfvars
terraform apply -var-file=../../policies/scp_ou_map.auto.tfvars
```

### 4) Make changes later

* **Update existing policy**: edit `policies/<Name>.json` → `terraform apply` in the env folder. (If previously imported in manage mode, TF updates the policy.)
* **Add new policy**:

  1. Create `policies/NewPolicy.json`.
  2. Add to `scp_ou_map.auto.tfvars` (or regenerate via `scp_audit` if you prefer).
  3. `terraform apply` in the env folder. TF creates & attaches it (manage mode).
* **Change attachments**: edit OU lists in `scp_ou_map.auto.tfvars` → re-apply.

  * The module **only creates missing** attachments. (If you want detach of extra ones, see FAQ below.)

---

## Common Operations

### Import existing policies (once)

If a policy name already exists and you’re in **manage mode**, import its ID so Terraform can own the content:

```bash
# Find policy ID(s)
aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
  --query "Policies[?Name=='FullAWSAccess'].{Name:Name,Id:Id}" --output table

# Import into the module state (run from env folder)
terraform import 'module.apply_scps.aws_organizations_policy.managed_scps["FullAWSAccess"]' p-XXXXXXXX
```

Re-apply afterwards.

### Attach-only mode

If you **don’t** want Terraform to manage JSON content, set:

```hcl
manage_policies = false
```

* Terraform will attach by **policy name** only (no JSON files needed).
* The module still **diffs** attachments and avoids duplicates.

---

## Troubleshooting

**Q: `DuplicatePolicyAttachmentException`**

* Cause: trying to reattach a policy that’s already attached.
* Fix: The `scp_apply` module **diffs** current vs desired and only creates **missing** attachments. Ensure you are using the updated module version (with the “diff” logic). Re-run `terraform plan` to verify zero attach ops when already attached.

**Q: “Policy name conflict … Import them or set manage\_policies=false.”**

* You’re in **manage mode**, and the policy already exists in the org.
* Import once (see **Common Operations**), or switch to `manage_policies=false`.

**Q: “Invalid value for path … no file exists at policies/<Name>.json”**

* In manage mode, each policy in `scp_ou_map` must have a JSON file in `scp_base_path`.
* Export with `scp_audit -var='scp_base_path=../../policies'` or copy the files into `policies/`.

**Q: “Unknown OU token(s)”**

* OU token must be an **OU name**, an **OU ID** (`ou-...`), or `"ROOT"`.
* Ensure the names exist and are **unique** (the apply module checks this).

**Q: “Value for undeclared variable …”**

* The root/env folder is missing a `variable` block you’re trying to pass via `-var-file`.
* Add it to the env’s `variables.tf` or remove it from your tfvars.

**Q: “Invalid single-argument block definition”**

* Use multi-line `variable` blocks (not one-line with both `type` and `default`).

**Q: `scp_ou_map.auto.tfvars` not found**

* Check the path. If `scp_audit` wrote under `modules/scp_audit/policies/`, either:

  * Run `scp_audit` with `-var='scp_base_path=../../policies'`, or
  * Reference the module path in your `-var-file`, e.g. `-var-file=../../modules/scp_audit/policies/scp_ou_map.auto.tfvars`.

---

## Permissions & Safety

* Run from the **management account** (or delegated admin) of each org.
* Default `skip_destroy = true` on attachments to avoid accidental detach.
* Consider least-privilege roles: separate **read-only** for export and **manage** for apply.

---

## Command Cheat Sheet

```bash
# 1) Export to repo-level policies/
cd modules/scp_audit
terraform init
terraform apply -var='scp_base_path=../../policies'

# 2) Apply to NONPROD (manage mode; one-time imports if needed)
cd ../../envs/nonprod
terraform init
terraform plan  -var-file=../../policies/scp_ou_map.auto.tfvars
terraform apply -var-file=../../policies/scp_ou_map.auto.tfvars

# 3) Apply to PROD
cd ../prod
terraform init
terraform plan  -var-file=../../policies/scp_ou_map.auto.tfvars
terraform apply -var-file=../../policies/scp_ou_map.auto.tfvars

# Import existing policy (example)
terraform import 'module.apply_scps.aws_organizations_policy.managed_scps["FullAWSAccess"]' p-XXXXXXXX
```

---

### FAQ

* **Can I detach policies not listed in `scp_ou_map`?**
  By default we **don’t detach** to be safe. If you want a “make it match exactly” mode, we can add a `detach_unlisted = true` toggle that computes the inverse diff and removes extra attachments.

* **Can I attach at the root?**
  Yes: include `"ROOT"` in the OU list for a policy.

* **My policy names have spaces or special chars.**
  The exporter writes file names safely; the HCL map quotes keys when needed. The apply module uses the **policy name** (not filename) as source of truth.
