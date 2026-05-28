################################################################################
# Pilot environment — wires the three migration tooling modules together and
# provisions the target Aurora/RDS/EFS/FSx so DMS endpoints + DataSync locations
# have something to point at.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  servers     = yamldecode(file("${path.module}/../../../inventory/servers.yaml")).servers
  databases   = yamldecode(file("${path.module}/../../../inventory/databases.yaml")).databases
  file_shares = yamldecode(file("${path.module}/../../../inventory/file_shares.yaml")).file_shares

  common_tags = {
    Project     = "aws-rehost-migration-tools"
    Environment = var.environment
    Region      = var.region
    Wave        = "pilot"
  }
}

############################
# KMS CMK
############################

resource "aws_kms_key" "this" {
  description             = "Migration tooling CMK — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/rehost-migration-${var.environment}"
  target_key_id = aws_kms_key.this.id
}

############################
# Network (migration VPC + endpoints)
############################

module "network" {
  source      = "../../modules/network"
  environment = var.environment
  region      = var.region

  public_subnets = {
    a = { cidr = "10.100.1.0/24", az = "${var.region}a" }
    b = { cidr = "10.100.2.0/24", az = "${var.region}b" }
  }
  private_subnets = {
    a = { cidr = "10.100.10.0/24", az = "${var.region}a", nat_key = "a" }
    b = { cidr = "10.100.11.0/24", az = "${var.region}b", nat_key = "b" }
  }
  on_prem_cidrs = var.on_prem_cidrs
  tags          = local.common_tags
}

############################
# Target Aurora / RDS clusters per database
############################

# CORE BANKING — Oracle → Aurora PostgreSQL 15
resource "aws_rds_cluster" "aurora_pg" {
  cluster_identifier      = "aurora-pg-corebanking-${var.environment}"
  engine                  = "aurora-postgresql"
  engine_version          = "15.4"
  database_name           = "corebanking"
  master_username         = "dbadmin"
  manage_master_user_password = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  db_subnet_group_name    = var.target_db_subnet_group_name
  vpc_security_group_ids  = [var.target_db_sg_id]
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.this.arn
  deletion_protection     = true
  backup_retention_period = 35
  skip_final_snapshot     = false
  final_snapshot_identifier = "aurora-pg-corebanking-final-${var.environment}"

  tags = merge(local.common_tags, { DatabaseId = "db-corebanking" })

  lifecycle { ignore_changes = [master_password, final_snapshot_identifier] }
}

resource "aws_rds_cluster_instance" "aurora_pg_writer" {
  cluster_identifier = aws_rds_cluster.aurora_pg.id
  identifier         = "aurora-pg-corebanking-writer"
  instance_class     = "db.r7g.2xlarge"
  engine             = aws_rds_cluster.aurora_pg.engine
  engine_version     = aws_rds_cluster.aurora_pg.engine_version
  performance_insights_enabled = true
  tags               = local.common_tags
}

# CUSTOMER, PRODUCT — MySQL → Aurora MySQL 3.x
resource "aws_rds_cluster" "aurora_mysql" {
  for_each = toset(["customer", "product"])

  cluster_identifier          = "aurora-mysql-${each.value}-${var.environment}"
  engine                      = "aurora-mysql"
  engine_version              = "8.0.mysql_aurora.3.04.1"
  database_name               = "${each.value}_db"
  master_username             = "dbadmin"
  manage_master_user_password = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  db_subnet_group_name    = var.target_db_subnet_group_name
  vpc_security_group_ids  = [var.target_db_sg_id]
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.this.arn
  deletion_protection     = true
  backup_retention_period = 35
  skip_final_snapshot     = false
  final_snapshot_identifier = "aurora-mysql-${each.value}-final-${var.environment}"

  tags = merge(local.common_tags, { DatabaseId = "db-${each.value}" })

  lifecycle { ignore_changes = [master_password, final_snapshot_identifier] }
}

resource "aws_rds_cluster_instance" "aurora_mysql_writer" {
  for_each           = aws_rds_cluster.aurora_mysql
  cluster_identifier = each.value.id
  identifier         = "${each.value.cluster_identifier}-writer"
  instance_class     = "db.r7g.xlarge"
  engine             = each.value.engine
  engine_version     = each.value.engine_version
  performance_insights_enabled = true
  tags               = local.common_tags
}

# RISKANALYTICS, REPORTING — SQL Server → RDS SQL Server
resource "aws_db_instance" "sqlserver" {
  for_each = toset(["riskanalytics", "reporting"])

  identifier             = "rds-sqlserver-${each.value}-${var.environment}"
  engine                 = "sqlserver-se"
  engine_version         = "15.00"
  instance_class         = "db.m5.2xlarge"
  allocated_storage      = each.value == "riskanalytics" ? 2000 : 1000
  storage_type           = "gp3"
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.this.arn
  manage_master_user_password = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn
  username               = "dbadmin"
  db_subnet_group_name   = var.target_db_subnet_group_name
  vpc_security_group_ids = [var.target_db_sg_id]
  multi_az               = false   # pilot — flip to true for prod
  deletion_protection    = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "rds-sqlserver-${each.value}-final-${var.environment}"
  license_model          = "license-included"
  backup_retention_period = 14
  performance_insights_enabled = true

  tags = merge(local.common_tags, { DatabaseId = "db-${each.value}" })

  lifecycle { ignore_changes = [password, final_snapshot_identifier] }
}

############################
# Target EFS + FSx
############################

resource "aws_efs_file_system" "finreports" {
  encrypted        = true
  kms_key_id       = aws_kms_key.this.arn
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(local.common_tags, { ShareId = "fs-finreports" })
}

resource "aws_efs_mount_target" "finreports" {
  for_each       = toset(module.network.private_subnet_ids)
  file_system_id = aws_efs_file_system.finreports.id
  subnet_id      = each.value
  security_groups = [var.target_efs_sg_id]
}

resource "aws_fsx_windows_file_system" "customerdata" {
  storage_capacity     = 4096
  storage_type         = "SSD"
  subnet_ids           = [module.network.private_subnet_ids[0]]
  throughput_capacity  = 64
  active_directory_id  = var.target_fsx_active_directory_id
  kms_key_id           = aws_kms_key.this.arn
  deployment_type      = "SINGLE_AZ_2"
  automatic_backup_retention_days = 14
  security_group_ids   = [var.target_efs_sg_id]

  tags = merge(local.common_tags, { ShareId = "fs-customerdata" })
}

# DataSync target locations
resource "aws_datasync_location_efs" "finreports" {
  efs_file_system_arn = aws_efs_file_system.finreports.arn
  ec2_config {
    security_group_arns = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/${var.target_efs_sg_id}",
    ]
    subnet_arn = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:subnet/${module.network.private_subnet_ids[0]}"
  }
  subdirectory = "/"
  tags         = local.common_tags
}

resource "aws_datasync_location_fsx_windows_file_system" "customerdata" {
  fsx_filesystem_arn = aws_fsx_windows_file_system.customerdata.arn
  security_group_arns = [
    "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/${var.target_efs_sg_id}",
  ]
  user     = "datasync_svc"
  password = "PLACEHOLDER_SET_VIA_SECRETS"   # rotate via aws_datasync_location_fsx_windows_file_system update
  domain   = "CORP"
  subdirectory = "/customerdata"
  tags     = local.common_tags

  lifecycle { ignore_changes = [password] }
}

############################
# Enrich the parsed inventory with the target endpoint addresses that
# the DMS / DataSync modules need.
############################

locals {
  aurora_pg_endpoint    = aws_rds_cluster.aurora_pg.endpoint
  aurora_mysql_endpoints = { for k, c in aws_rds_cluster.aurora_mysql : k => c.endpoint }
  sqlserver_endpoints    = { for k, i in aws_db_instance.sqlserver       : k => i.endpoint }

  enriched_databases = [
    for db in local.databases : merge(db, {
      target_endpoint      = (
        db.id == "db-corebanking"   ? local.aurora_pg_endpoint :
        db.id == "db-customer"       ? local.aurora_mysql_endpoints["customer"] :
        db.id == "db-product"        ? local.aurora_mysql_endpoints["product"] :
        db.id == "db-riskanalytics"  ? local.sqlserver_endpoints["riskanalytics"] :
        db.id == "db-reporting"      ? local.sqlserver_endpoints["reporting"] : null
      )
      target_database_name = (
        contains(["db-corebanking"], db.id)       ? "corebanking" :
        contains(["db-customer"], db.id)          ? "customer_db" :
        contains(["db-product"], db.id)           ? "product_db" :
        db.name
      )
    })
  ]

  datasync_target_locations = {
    "fs-finreports"   = aws_datasync_location_efs.finreports.arn
    "fs-customerdata" = aws_datasync_location_fsx_windows_file_system.customerdata.arn
  }
}

############################
# Modules
############################

module "mgn" {
  source = "../../modules/mgn"

  environment       = var.environment
  kms_key_arn       = aws_kms_key.this.arn
  staging_subnet_id = module.network.private_subnet_ids[0]
  mgn_staging_sg_id = module.network.mgn_staging_sg_id

  target_subnet_id_by_tier = { app = var.target_app_subnet_id }
  target_app_sg_id         = var.target_app_sg_id

  servers = local.servers
  tags    = local.common_tags
}

module "dms" {
  source = "../../modules/dms"

  environment        = var.environment
  kms_key_arn        = aws_kms_key.this.arn
  private_subnet_ids = module.network.private_subnet_ids
  dms_sg_id          = module.network.dms_sg_id

  databases = local.enriched_databases
  tags      = local.common_tags
}

module "datasync" {
  source = "../../modules/datasync"

  environment              = var.environment
  kms_key_arn              = aws_kms_key.this.arn
  private_subnet_arns      = [for s in module.network.private_subnet_ids :
                              "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:subnet/${s}"]
  datasync_vpc_endpoint_id = "vpce-pending"     # populated after first apply
  datasync_endpoint_sg_arn = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/${module.network.datasync_endpoint_sg_id}"

  file_shares      = local.file_shares
  target_locations = local.datasync_target_locations
  tags             = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  environment                 = var.environment
  region                      = var.region
  kms_key_arn                 = aws_kms_key.this.arn
  email_subscribers           = var.email_subscribers
  dms_replication_instance_id = module.dms.replication_instance_id
  dms_task_ids                = [for id, _ in module.dms.task_ids : module.dms.task_ids[id]]
  datasync_task_arns          = module.datasync.task_arns
  mgn_source_server_ids       = []   # populated post-agent-registration
  tags                        = local.common_tags
}

############################
# Outputs
############################

output "vpc_id"                  { value = module.network.vpc_id }
output "dms_replication_instance" { value = module.dms.replication_instance_id }
output "aurora_pg_endpoint"      { value = aws_rds_cluster.aurora_pg.endpoint }
output "sqlserver_endpoints"     { value = local.sqlserver_endpoints }
output "aurora_mysql_endpoints"  { value = local.aurora_mysql_endpoints }
output "efs_id"                  { value = aws_efs_file_system.finreports.id }
output "fsx_dns_name"            { value = aws_fsx_windows_file_system.customerdata.dns_name }
output "dashboard_name"          { value = module.monitoring.dashboard_name }
output "alerts_sns_arn"          { value = module.monitoring.sns_topic_arn }
