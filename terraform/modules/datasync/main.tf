################################################################################
# AWS DataSync — agent registration, source/target locations, tasks.
#
# IMPORTANT: agent VMs are deployed on-prem manually (TIG §C.2 step 1) and the
# activation key is captured into an SSM parameter (`/datasync/agent/<name>/key`)
# before this module runs. Terraform reads those keys and registers the agents.
################################################################################

locals {
  shares    = { for s in var.file_shares : s.id => s }
  nfs_shares = { for k, s in local.shares : k => s if s.protocol == "nfs" }
  smb_shares = { for k, s in local.shares : k => s if s.protocol == "smb" }
}

############################
# Agents (two for HA — DS-NFR-03)
############################

data "aws_ssm_parameter" "agent_keys" {
  for_each = toset(var.agent_names)
  name     = "/datasync/agent/${each.value}/key"
}

resource "aws_datasync_agent" "this" {
  for_each       = toset(var.agent_names)
  name           = each.value
  activation_key = data.aws_ssm_parameter.agent_keys[each.value].value
  vpc_endpoint_id = var.datasync_vpc_endpoint_id
  subnet_arns    = var.private_subnet_arns
  security_group_arns = [var.datasync_endpoint_sg_arn]

  tags = merge(var.tags, { Component = "datasync-agent" })
}

############################
# Source locations
############################

resource "aws_datasync_location_nfs" "source" {
  for_each      = local.nfs_shares
  server_hostname = each.value.source_server
  subdirectory  = each.value.source_mount_path

  on_prem_config {
    agent_arns = [for a in aws_datasync_agent.this : a.arn]
  }

  mount_options {
    version = each.value.nfs_version
  }

  tags = merge(var.tags, { ShareId = each.value.id })
}

# SMB credentials live in Secrets Manager — DataSync needs username/password
# inline, so we read the secret once at plan time.
data "aws_secretsmanager_secret_version" "smb_creds" {
  for_each  = local.smb_shares
  secret_id = each.value.source_user_secret_id
}

resource "aws_datasync_location_smb" "source" {
  for_each       = local.smb_shares
  server_hostname = each.value.source_server
  subdirectory   = "/${each.value.source_share}"

  agent_arns = [for a in aws_datasync_agent.this : a.arn]
  user       = jsondecode(data.aws_secretsmanager_secret_version.smb_creds[each.key].secret_string).username
  password   = jsondecode(data.aws_secretsmanager_secret_version.smb_creds[each.key].secret_string).password
  domain     = each.value.source_domain

  mount_options {
    version = "SMB${each.value.smb_version}"
  }

  tags = merge(var.tags, { ShareId = each.value.id })
}

############################
# Target locations — created by environment (EFS / FSx provisioned separately)
# and passed in via `var.target_locations`.
############################

############################
# CloudWatch log group + Tasks
############################

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "datasync-tasks-${var.environment}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_datasync_task" "this" {
  for_each = local.shares

  name = "task-${each.value.id}-${var.environment}"
  source_location_arn = each.value.protocol == "nfs" ?
    aws_datasync_location_nfs.source[each.key].arn :
    aws_datasync_location_smb.source[each.key].arn
  destination_location_arn = var.target_locations[each.key]

  cloudwatch_log_group_arn = aws_cloudwatch_log_group.tasks.arn

  options {
    verify_mode           = each.value.verify_mode
    overwrite_mode        = "ALWAYS"
    posix_permissions     = each.value.protocol == "nfs" ? "PRESERVE" : "NONE"
    mtime                 = "PRESERVE"
    atime                 = "BEST_EFFORT"
    preserve_deleted_files = "REMOVE"
    log_level             = "TRANSFER"
    bytes_per_second      = -1   # unlimited; throttling applied via schedule overrides
    transfer_mode         = "CHANGED"
    task_queueing         = "ENABLED"
  }

  schedule {
    schedule_expression = each.value.schedule_cron
  }

  tags = merge(var.tags, { ShareId = each.value.id, Priority = each.value.priority })
}
