terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# ---------------- 1) Discover org & OUs ----------------
data "aws_organizations_organization" "org" {}
locals { root_id = data.aws_organizations_organization.org.roots[0].id }

data "aws_organizations_organizational_unit_descendant_organizational_units" "all" {
  parent_id = local.root_id
}

locals {
  ou_children = try(data.aws_organizations_organizational_unit_descendant_organizational_units.all.children, [])
  ou_by_name  = { for ou in local.ou_children : ou.name => ou.id }
  ou_names    = keys(local.ou_by_name)

  desired_pairs = flatten([
    for policy_name, tokens in var.scp_ou_map : [
      for t in tokens : { policy_name = policy_name, token = t }
    ]
  ])

  tokens_all        = distinct([for p in local.desired_pairs : p.token])
  token_is_ou_id    = { for t in local.tokens_all : t => length(regexall("^ou-[a-z0-9]{4}-[a-z0-9]{8,32}$", t)) > 0 }
  unknown_ou_tokens = [
    for t in local.tokens_all :
    t if t != "ROOT" && !contains(local.ou_names, t) && !local.token_is_ou_id[t]
  ]
}

resource "terraform_data" "assert_ou_tokens" {
  lifecycle {
    precondition {
      condition     = length(local.unknown_ou_tokens) == 0
      error_message = "Unknown OU token(s): ${join(", ", local.unknown_ou_tokens)} (use OU name, OU id, or \"ROOT\")."
    }
  }
}

# Resolve target IDs
locals {
  desired_attachment_objects = [
    for p in local.desired_pairs : {
      policy_name = p.policy_name
      target_id   = p.token == "ROOT" ? local.root_id : (local.token_is_ou_id[p.token] ? p.token : local.ou_by_name[p.token])
    }
  ]
  target_ids = distinct([for o in local.desired_attachment_objects : o.target_id])
}

# ---------------- 2) Policies (discover + optional manage) ----------------
data "aws_organizations_policies" "all_scps" {
  filter = "SERVICE_CONTROL_POLICY"
}

data "aws_organizations_policy" "existing_by_id" {
  for_each  = toset(try(data.aws_organizations_policies.all_scps.ids, []))
  policy_id = each.value
}

locals {
  existing_policy_ids_by_name = {
    for id, d in data.aws_organizations_policy.existing_by_id : d.name => id
  }
}

# Manage from files (create/update). If a name already exists, import first.
locals {
  scp_base_path_abs    = abspath("${path.module}/${var.scp_base_path}")
  policy_names         = keys(var.scp_ou_map)
  policy_file_for_name = {
    for name in local.policy_names :
    name => "${local.scp_base_path_abs}/${name}.json"
  }
  name_conflicts = var.manage_policies ? [
    for n in local.policy_names : n if contains(keys(local.existing_policy_ids_by_name), n)
  ] : []
  missing_policy_files = var.manage_policies ? [
    for n in local.policy_names : n if !fileexists(local.policy_file_for_name[n])
  ] : []
}

resource "terraform_data" "assert_manage_ready" {
  count = var.manage_policies ? 1 : 0
  lifecycle {
    precondition {
      condition     = length(local.name_conflicts) == 0
      error_message = "Existing policy names must be imported before manage mode: ${join(", ", local.name_conflicts)}"
    }
    precondition {
      condition     = length(local.missing_policy_files) == 0
      error_message = "Missing JSON file(s) under ${local.scp_base_path_abs}: ${join(", ", local.missing_policy_files)}"
    }
  }
}

resource "aws_organizations_policy" "managed_scps" {
  for_each    = var.manage_policies ? var.scp_ou_map : {}
  name        = each.key
  description = "${each.key} (managed by Terraform)"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file(local.policy_file_for_name[each.key])
}

locals {
  policy_id_by_name = var.manage_policies ? {
    for n in local.policy_names : n => aws_organizations_policy.managed_scps[n].id
  } : local.existing_policy_ids_by_name
}

# Attach-only guard: ensure all desired names exist
resource "terraform_data" "assert_known_policies" {
  count = var.manage_policies ? 0 : 1
  lifecycle {
    precondition {
      condition     = alltrue([for n in keys(var.scp_ou_map) : contains(keys(local.policy_id_by_name), n)])
      error_message = "These policy names do not exist in the org (attach-only): ${join(", ", [for n in keys(var.scp_ou_map) : n if !contains(keys(local.policy_id_by_name), n)])}"
    }
  }
}

# ---------------- 3) Existing attachments vs desired (create only missing) ----------------
data "aws_organizations_policies_for_target" "current" {
  for_each  = toset(local.target_ids)
  target_id = each.value
  filter    = "SERVICE_CONTROL_POLICY"
}

locals {
  # Existing attachments as "policyId::targetId"
  existing_attach_keys = toset(flatten([
    for tid, ds in data.aws_organizations_policies_for_target.current : [
      for pid in ds.ids : "${pid}::${tid}"
    ]
  ]))

  # Desired attachments by resolved policy ID
  desired_attach_objs_by_id = [
    for o in local.desired_attachment_objects : {
      key_name  = "${o.policy_name}::${o.target_id}"                # human key
      key_id    = "${local.policy_id_by_name[o.policy_name]}::${o.target_id}" # id key for diff
      policy_id = local.policy_id_by_name[o.policy_name]
      target_id = o.target_id
    }
  ]

  # Only create those NOT already attached
  to_create = {
    for o in local.desired_attach_objs_by_id :
    o.key_name => { policy_id = o.policy_id, target_id = o.target_id }
    if !contains(local.existing_attach_keys, o.key_id)
  }
}

resource "aws_organizations_policy_attachment" "attachments" {
  for_each     = local.to_create
  policy_id    = each.value.policy_id
  target_id    = each.value.target_id
  skip_destroy = var.attachment_skip_destroy

  depends_on = [
    terraform_data.assert_ou_tokens,
    terraform_data.assert_manage_ready,
    terraform_data.assert_known_policies
  ]
}
