# vars.tf
variable "scp_base_path" {
  description = "Relative path (inside this module) to write/read SCP JSONs"
  type        = string
  default     = "policies"  # <-- literal only
}

variable "include_root" {
  description = "Also include policies attached to the org Root"
  type        = bool
  default     = false
}

variable "export_all_scps" {
  description = "If true, export ALL org SCPs; if false, only those attached to some OU (and root if include_root=true)"
  type        = bool
  default     = false
}
