variable "region" {
  type    = string
  default = "us-east-1"
}

variable "profile" {
  type    = string
  default = "org-nonprod-mgmt"
}

variable "manage_policies" {
  type        = bool
  default     = true   # true = create/update from policies/*.json
}

variable "scp_base_path" {
  type    = string
  default = "../../policies"
}

variable "scp_ou_map" {
  type    = map(list(string))
  default = {}
}

variable "attachment_skip_destroy" {
  type    = bool
  default = true
}
