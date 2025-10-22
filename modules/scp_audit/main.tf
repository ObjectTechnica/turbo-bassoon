# Compute absolute export directory from module-relative var (Option A)
locals {
  scp_base_path = abspath("${path.module}/${var.scp_base_path}")
}

# ---- Discover org, root, and all descendant OUs ----
data "aws_organizations_organization" "org" {}

locals {
  root_id = data.aws_organizations_organization.org.roots[0].id
}

data "aws_organizations_organizational_unit_descendant_organizational_units" "all" {
  parent_id = local.root_id
}

locals {
  ou_children   = try(data.aws_organizations_organizational_unit_descendant_organizational_units.all.children, [])
  ou_ids        = [for ou in local.ou_children : ou.id]
  ou_name_by_id = { for ou in local.ou_children : ou.id => ou.name }

  # detect duplicate OU names (unsafe to export by name)
  all_ou_names = [for ou in local.ou_children : ou.name]
  dup_ou_names = [
    for nm in distinct(local.all_ou_names) : nm
    if length([for x in local.all_ou_names : x if x == nm]) > 1
  ]
}

resource "terraform_data" "assert_unique_ou_names" {
  lifecycle {
    precondition {
      condition     = length(local.dup_ou_names) == 0
      error_message = "Duplicate OU names detected: ${join(", ", local.dup_ou_names)}. Please disambiguate before exporting."
    }
  }
}

# ---- For each OU (and optional root), read its attached SCPs ----
locals {
  targets = var.include_root ? concat([local.root_id], local.ou_ids) : local.ou_ids
}

data "aws_organizations_policies_for_target" "by_target" {
  for_each  = toset(local.targets)
  target_id = each.value
  filter    = "SERVICE_CONTROL_POLICY"
}

# Build attachment pairs from IDs
locals {
  # [{ policy_id = "p-xxxx", target_id = "ou-xxxx" }, ...]
  attachment_pairs = flatten([
    for target_id, ds in data.aws_organizations_policies_for_target.by_target : [
      for pid in ds.ids : {
        policy_id = pid
        target_id = target_id
      }
    ]
  ])
}

# ---- Enumerate policies to export ----
locals {
  attached_policy_ids = distinct([for x in local.attachment_pairs : x.policy_id])
}

data "aws_organizations_policies" "all_scps" {
  filter = "SERVICE_CONTROL_POLICY"
}

locals {
  all_policy_ids   = data.aws_organizations_policies.all_scps.ids
  policy_ids_final = var.export_all_scps ? local.all_policy_ids : local.attached_policy_ids
}

# ---- Read each policy's content (and name) by ID ----
data "aws_organizations_policy" "by_id" {
  for_each  = { for id in local.policy_ids_final : id => id }
  policy_id = each.value
}

# ---- Export policy JSONs ----
# Safe filename using regex-capable replace():
# 1) replace disallowed chars with "_"
# 2) collapse runs of "_" to single "_"
# 3) trim leading/trailing "_"
locals {
  policy_meta = {
    for id, d in data.aws_organizations_policy.by_id :
    id => {
      name = d.name
      safe_name = trim(
        replace(
          replace(d.name, "[^0-9A-Za-z_.-]", "_"),
          "_+", "_"
        ),
        "_"
      )
      # Normalize formatting (valid JSON)
      pretty_json = jsonencode(jsondecode(d.content))
    }
  }
}

resource "local_file" "policy_json" {
  for_each = local.policy_meta
  filename = "${local.scp_base_path}/${each.value.safe_name}.json"
  content  = each.value.pretty_json
  lifecycle { prevent_destroy = true }
}

# Pretty-print JSONs with jq (-S sorts keys)
resource "null_resource" "format_policy_json" {
  for_each = local.policy_meta
  triggers = {
    content_hash = sha256(local.policy_meta[each.key].pretty_json)
    path         = local_file.policy_json[each.key].filename
  }
  depends_on = [local_file.policy_json]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOC
      jq -S . "${local_file.policy_json[each.key].filename}" > "${local_file.policy_json[each.key].filename}.tmp" && \
      mv "${local_file.policy_json[each.key].filename}.tmp" "${local_file.policy_json[each.key].filename}"
    EOC
  }
}

# ---- Build the policy-name -> OU-names map AFTER resolving names ----
locals {
  scp_ou_map = {
    for pn in distinct([
      for pair in local.attachment_pairs : local.policy_meta[pair.policy_id].name
      if contains(keys(local.policy_meta), pair.policy_id)
    ]) :
    pn => sort(distinct([
      for pair in local.attachment_pairs :
      lookup(local.ou_name_by_id, pair.target_id, "ROOT")
      if contains(keys(local.policy_meta), pair.policy_id) && local.policy_meta[pair.policy_id].name == pn
    ]))
  }
}

# ---- HCL rendering of scp_ou_map into scp_ou_map.auto.tfvars ----
locals {
  scp_names_sorted = sort(keys(local.scp_ou_map))

  # Unquote key if it's a valid HCL identifier; otherwise quote it.
  scp_ou_map_hcl_lines = [
    for pn in local.scp_names_sorted :
    "  ${length(regexall("^[A-Za-z_][A-Za-z0-9_]*$", pn)) > 0 ? pn : format("%q", pn)} = [${join(", ", [for ou in sort(local.scp_ou_map[pn]) : format("%q", ou)])}]"
  ]

  # Trailing newline achieved by appending an empty string as the last element
  scp_ou_map_hcl = join("\n", concat(
    ["scp_ou_map = {"],
    local.scp_ou_map_hcl_lines,
    ["}", ""]
  ))
}

resource "local_file" "policy_map_hcl" {
  filename = "${local.scp_base_path}/scp_ou_map.auto.tfvars"
  content  = local.scp_ou_map_hcl
  lifecycle { prevent_destroy = true }
}
