terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
  # Optional: remote state just for PROD (uncomment + fill if you use S3)
  # backend "s3" {
  #   bucket         = "my-tf-state-bucket"
  #   key            = "scp/prod.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
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
