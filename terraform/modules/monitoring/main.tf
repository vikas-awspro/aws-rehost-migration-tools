################################################################################
# Single dashboard + SNS topic carrying alerts for all three migration streams
# (TRD §8). Alarm thresholds match the NFR targets.
################################################################################

resource "aws_sns_topic" "alerts" {
  name              = "migration-alerts-${var.environment}"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.email_subscribers)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

############################
# MGN alarms — replication lag per server
############################

resource "aws_cloudwatch_metric_alarm" "mgn_lag" {
  for_each = toset(var.mgn_source_server_ids)

  alarm_name          = "mgn-lag-${each.value}-${var.environment}"
  alarm_description   = "MGN replication lag > 60s for ${each.value}"
  namespace           = "AWS/MGN"
  metric_name         = "ReplicationLag"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { SourceServerID = each.value }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = merge(var.tags, { Stream = "mgn" })
}

############################
# DMS alarms — CDC lag, task error, storage
############################

resource "aws_cloudwatch_metric_alarm" "dms_cdc_lag" {
  for_each = toset(var.dms_task_ids)

  alarm_name          = "dms-cdc-lag-${each.value}-${var.environment}"
  alarm_description   = "DMS CDC target lag > 30s for ${each.value} (DMS-NFR-02)"
  namespace           = "AWS/DMS"
  metric_name         = "CDCLatencyTarget"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 30
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ReplicationInstanceIdentifier = var.dms_replication_instance_id
    ReplicationTaskIdentifier     = each.value
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = merge(var.tags, { Stream = "dms" })
}

resource "aws_cloudwatch_metric_alarm" "dms_storage" {
  alarm_name          = "dms-storage-high-${var.environment}"
  alarm_description   = "DMS RI storage > 85% (DMS-NFR-03)"
  namespace           = "AWS/DMS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.dms_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ReplicationInstanceIdentifier = var.dms_replication_instance_id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = merge(var.tags, { Stream = "dms" })
}

############################
# DataSync alarms — task failures, throughput
############################

resource "aws_cloudwatch_metric_alarm" "datasync_task_failure" {
  for_each = var.datasync_task_arns

  alarm_name          = "datasync-task-failed-${each.key}-${var.environment}"
  alarm_description   = "DataSync task ${each.key} reported a failed execution"
  namespace           = "AWS/DataSync"
  metric_name         = "FilesVerifyFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { TaskArn = each.value }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = merge(var.tags, { Stream = "datasync" })
}

############################
# Dashboard
############################

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "Migration-${var.environment}"
  dashboard_body = templatefile("${path.module}/dashboard.json.tpl", {
    region                       = var.region
    environment                  = var.environment
    dms_replication_instance_id  = var.dms_replication_instance_id
    dms_task_ids                 = jsonencode(var.dms_task_ids)
    mgn_source_server_ids        = jsonencode(var.mgn_source_server_ids)
    datasync_task_arns           = jsonencode([for arn in var.datasync_task_arns : arn])
  })
}
