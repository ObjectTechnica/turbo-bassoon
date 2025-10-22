provider "aws" {
  region  = var.region
}

module "apply_scps" {
  source                  = "../../modules/scp_apply"
  manage_policies         = var.manage_policies
  scp_base_path           = var.scp_base_path
  scp_ou_map              = var.scp_ou_map
  attachment_skip_destroy = var.attachment_skip_destroy
}
