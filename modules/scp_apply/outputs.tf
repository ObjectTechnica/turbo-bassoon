output "attachment_count" {
  value = length(aws_organizations_policy_attachment.attachments)
}

output "policy_ids_by_name" {
  value = local.policy_id_by_name
}

output "attached_pairs" {
  description = "List of {policy_name, target_id} pairs applied."
  value = [
    for k, v in aws_organizations_policy_attachment.attachments :
    { policy_name = split("::", k)[0], target_id = v.target_id }
  ]
}
