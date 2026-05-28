output "replication_instance_arn" { value = aws_dms_replication_instance.this.replication_instance_arn }
output "replication_instance_id"  { value = aws_dms_replication_instance.this.replication_instance_id }
output "task_arns"                { value = { for k, t in aws_dms_replication_task.this : k => t.replication_task_arn } }
output "task_ids"                 { value = { for k, t in aws_dms_replication_task.this : k => t.replication_task_id } }
output "log_group"                { value = aws_cloudwatch_log_group.tasks.name }
