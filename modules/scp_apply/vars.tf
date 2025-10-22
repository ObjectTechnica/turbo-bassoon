variable "scp_ou_map" {
  description = <<EOT
Mapping of POLICY NAME => list of OU tokens to attach to.
Each OU token may be:
  - an OU NAME (must be unique in the tree),
  - an OU ID like "ou-abcd-12345678",
  - or the literal string "ROOT" to attach at the org root.
EOT
  type = map(list(string))
}

variable "manage_policies" {
  description = "If true, create/update SCPs from JSON before attaching; if false, attach to existing policies by name."
  type        = bool
  default     = false
}

variable "scp_base_path" {
  description = "Directory with policy JSON files (used only when manage_policies = true)."
  type        = string
  default     = "policies"
}

variable "policy_file_map" {
  description = "Optional mapping of policy name => explicit JSON file path (overrides scp_base_path/<name>.json)."
  type        = map(string)
  default     = {}
}

variable "attachment_skip_destroy" {
  description = "If true, destroying state will not detach SCPs (defensive safety)."
  type        = bool
  default     = true
}