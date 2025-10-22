module "audit_scp" {
  source = "./modules/scp_audit"
  # This Module pulls all existing SCP's that are currently tied to an OU
  # SCP's not currently tied to an OU will be left out.
}
/*
module "apply_scps" {
  source = "./modules/scp_apply"

  manage_policies         = var.manage_policies
  scp_base_path           = var.scp_base_path
  policy_file_map         = var.policy_file_map
  scp_ou_map              = var.scp_ou_map

  # optional (module default is true)
  attachment_skip_destroy = var.attachment_skip_destroy
}
*/