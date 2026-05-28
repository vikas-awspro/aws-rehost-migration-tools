################################################################################
# AWS DMS — replication instance + per-database endpoints + per-database tasks.
# Database list comes from inventory/databases.yaml, parsed in the environment.
################################################################################

locals {
  databases = { for db in var.databases : db.id => db }

  # Engine-name mapping for DMS endpoint resource.
  source_engine_for_dms = {
    oracle    = "oracle"
    sqlserver = "sqlserver"
    mysql     = "mysql"
    postgres  = "postgres"
  }
  target_engine_for_dms = {
    "aurora-postgresql" = "aurora-postgresql"
    "aurora-mysql"      = "aurora"
    "sqlserver"         = "sqlserver"
    "rds-postgres"      = "postgres"
    "rds-mysql"         = "mysql"
  }

  source_port_for_dms = {
    oracle    = 1521
    sqlserver = 1433
    mysql     = 3306
    postgres  = 5432
  }

  # All migration tasks use full-load + CDC per DMS-FR-05.
  task_settings_json = jsonencode({
    TargetMetadata = {
      TargetSchema       = ""
      SupportLobs        = true
      FullLobMode        = false
      LimitedSizeLobMode = true
      LobMaxSize         = var.lob_max_size_kb
      BatchApplyEnabled  = false
    }
    FullLoadSettings = {
      TargetTablePrepMode             = "DO_NOTHING"   # SCT created schema for heterogeneous; DMS doesn't drop tables
      CreatePkAfterFullLoad           = true
      StopTaskCachedChangesApplied    = false
      StopTaskCachedChangesNotApplied = false
      MaxFullLoadSubTasks             = 8
      TransactionConsistencyTimeout   = 600
      CommitRate                      = 50000
    }
    Logging = {
      EnableLogging = true
      LogComponents = [
        { Id = "SOURCE_UNLOAD",  Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_LOAD",    Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "SOURCE_CAPTURE", Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TARGET_APPLY",   Severity = "LOGGER_SEVERITY_DEFAULT" },
        { Id = "TASK_MANAGER",   Severity = "LOGGER_SEVERITY_DEFAULT" },
      ]
    }
    ValidationSettings = {
      EnableValidation            = true
      ThreadCount                 = 5
      FailureMaxCount             = 0
      RecordFailureDelayInMinutes = 5
      ValidationMode              = "ROW_LEVEL"
    }
    ErrorBehavior = {
      DataErrorPolicy           = "LOG_ERROR"
      DataTruncationErrorPolicy = "LOG_ERROR"
      DataErrorEscalationPolicy = "SUSPEND_TABLE"
      DataErrorEscalationCount  = 50
      TableErrorPolicy          = "SUSPEND_TABLE"
      ApplyErrorInsertPolicy    = "LOG_ERROR"
      ApplyErrorUpdatePolicy    = "LOG_ERROR"
      ApplyErrorEscalationPolicy = "LOG_ERROR"
      FailOnNoTablesCaptured    = true
    }
  })
}

############################
# Subnet group + Replication Instance (DMS-FR-01)
############################

resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id          = "migration-pilot-${var.environment}"
  replication_subnet_group_description = "DMS subnet group — ${var.environment}"
  subnet_ids                           = var.private_subnet_ids
  tags                                 = var.tags
}

resource "aws_dms_replication_instance" "this" {
  replication_instance_id      = "dms-pilot-${var.environment}"
  replication_instance_class   = var.replication_instance_class
  engine_version               = var.engine_version
  allocated_storage            = var.allocated_storage_gb
  multi_az                     = true
  publicly_accessible          = false
  auto_minor_version_upgrade   = true
  replication_subnet_group_id  = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids       = [var.dms_sg_id]
  kms_key_arn                  = var.kms_key_arn
  preferred_maintenance_window = "sun:03:00-sun:04:00"

  tags = merge(var.tags, { Name = "dms-pilot-${var.environment}" })
}

############################
# Pre-create the CloudWatch log group with 90-day retention (DMS-FR-10)
############################

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "dms-tasks-${var.environment}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

############################
# Source + target endpoints (DMS-FR-02 / DMS-FR-03)
############################

# Secrets Manager — one secret per source DB credential, one per target.
data "aws_secretsmanager_secret_version" "source" {
  for_each  = local.databases
  secret_id = each.value.secrets_id
}

data "aws_secretsmanager_secret_version" "target" {
  for_each  = local.databases
  secret_id = each.value.target_secret_id
}

resource "aws_dms_endpoint" "source" {
  for_each      = local.databases
  endpoint_id   = "src-${each.value.id}-${var.environment}"
  endpoint_type = "source"
  engine_name   = local.source_engine_for_dms[each.value.source_engine]
  server_name   = each.value.source_host
  port          = local.source_port_for_dms[each.value.source_engine]
  database_name = try(each.value.source_sid, try(each.value.source_database, null))
  username      = jsondecode(data.aws_secretsmanager_secret_version.source[each.key].secret_string).username
  password      = jsondecode(data.aws_secretsmanager_secret_version.source[each.key].secret_string).password
  ssl_mode      = "verify-full"
  kms_key_arn   = var.kms_key_arn

  dynamic "oracle_settings" {
    for_each = each.value.source_engine == "oracle" ? [1] : []
    content {
      add_supplemental_logging = true
      use_logminer_reader      = false   # Binary Reader — faster on archive logs
    }
  }

  tags = merge(var.tags, { DatabaseId = each.value.id, Endpoint = "source" })
}

resource "aws_dms_endpoint" "target" {
  for_each      = local.databases
  endpoint_id   = "tgt-${each.value.id}-${var.environment}"
  endpoint_type = "target"
  engine_name   = local.target_engine_for_dms[each.value.target_engine]
  server_name   = each.value.target_endpoint
  port          = each.value.target_engine == "aurora-postgresql" || each.value.target_engine == "rds-postgres" ? 5432 :
                  each.value.target_engine == "sqlserver" ? 1433 : 3306
  database_name = each.value.target_database_name
  username      = jsondecode(data.aws_secretsmanager_secret_version.target[each.key].secret_string).username
  password      = jsondecode(data.aws_secretsmanager_secret_version.target[each.key].secret_string).password
  ssl_mode      = "verify-full"
  kms_key_arn   = var.kms_key_arn

  tags = merge(var.tags, { DatabaseId = each.value.id, Endpoint = "target" })
}

############################
# Migration tasks (DMS-FR-05)
############################

resource "aws_dms_replication_task" "this" {
  for_each = local.databases

  replication_task_id      = "task-${each.value.id}-${var.environment}"
  replication_instance_arn = aws_dms_replication_instance.this.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source[each.key].endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target[each.key].endpoint_arn
  migration_type           = "full-load-and-cdc"

  table_mappings = jsonencode({
    rules = [
      {
        rule-type      = "selection"
        rule-id        = "1"
        rule-name      = "include-${each.value.id}"
        object-locator = { schema-name = each.value.table_mapping_schema, table-name = "%" }
        rule-action    = "include"
      },
      {
        rule-type      = "selection"
        rule-id        = "2"
        rule-name      = "exclude-temp-tables"
        object-locator = { schema-name = each.value.table_mapping_schema, table-name = "TEMP_%" }
        rule-action    = "exclude"
      },
    ]
  })

  replication_task_settings = local.task_settings_json

  tags = merge(var.tags, {
    DatabaseId    = each.value.id
    MigrationType = each.value.migration_type
    Engine        = each.value.source_engine
  })

  lifecycle {
    ignore_changes = [replication_task_settings]
  }
}
