output "replication_template_id" {
  value = aws_mgn_replication_configuration_template.this.id
}

output "launch_template_ids" {
  value = { for k, lt in aws_launch_template.server : k => lt.id }
}

output "migrated_ec2_instance_profile_arn" {
  value = aws_iam_instance_profile.migrated_ec2.arn
}

output "post_launch_linux_doc"   { value = aws_ssm_document.post_launch_linux.name }
output "post_launch_windows_doc" { value = aws_ssm_document.post_launch_windows.name }
