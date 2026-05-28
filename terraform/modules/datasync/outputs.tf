output "agent_arns" { value = [for a in aws_datasync_agent.this : a.arn] }
output "task_arns"  { value = { for k, t in aws_datasync_task.this : k => t.arn } }
output "log_group"  { value = aws_cloudwatch_log_group.tasks.name }
