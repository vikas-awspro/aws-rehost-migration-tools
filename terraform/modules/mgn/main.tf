################################################################################
# AWS MGN — replication settings, IAM, launch templates per source server.
# Initialisation of MGN itself (the AWSServiceRoleForApplicationMigrationService
# service-linked role) happens on first console access; we ensure it exists
# here so a fresh account is fully bootstrapped.
################################################################################

############################
# Service-linked role
############################

resource "aws_iam_service_linked_role" "mgn" {
  aws_service_name = "mgn.amazonaws.com"
  description      = "Service-linked role for AWS Application Migration Service"
}

############################
# Replication settings (default for the region — TIG §A.3)
############################

resource "aws_mgn_replication_configuration_template" "this" {
  associate_default_security_group        = false
  bandwidth_throttling                    = var.bandwidth_throttling_mbps
  create_public_ip                        = false
  data_plane_routing                      = "PRIVATE_IP"        # via DX/VPN
  default_large_staging_disk_type         = "GP3"
  ebs_encryption                          = "CUSTOM"
  ebs_encryption_key_arn                  = var.kms_key_arn
  replication_server_instance_type        = var.replication_server_instance_type
  replication_servers_security_groups_ids = [var.mgn_staging_sg_id]
  staging_area_subnet_id                  = var.staging_subnet_id
  use_dedicated_replication_server        = false

  staging_area_tags = merge(var.tags, { Component = "mgn-staging" })

  depends_on = [aws_iam_service_linked_role.mgn]
}

############################
# IAM instance profile for migrated EC2s (SSM managed + agent)
############################

data "aws_iam_policy_document" "migrated_ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "migrated_ec2" {
  name               = "migrated-ec2-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.migrated_ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.migrated_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.migrated_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "migrated_ec2" {
  name = "migrated-ec2-${var.environment}"
  role = aws_iam_role.migrated_ec2.name
}

############################
# Per-server launch template
# `var.servers` is the parsed inventory/servers.yaml from the environment.
############################

locals {
  servers = { for s in var.servers : s.name => s }
}

resource "aws_launch_template" "server" {
  for_each = local.servers

  name          = "mgn-launch-${each.value.name}-${var.environment}"
  instance_type = each.value.target_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.migrated_ec2.arn
  }

  vpc_security_group_ids = [var.target_app_sg_id]

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.target_app_sg_id]
    subnet_id                   = var.target_subnet_id_by_tier[each.value.target_subnet]
  }

  block_device_mappings {
    device_name = "/dev/sda1"   # Linux root; Windows uses /dev/sda1 too on MGN
    ebs {
      volume_size           = each.value.storage_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name        = each.value.name
      Application = each.value.application
      Priority    = each.value.priority
      Source      = "mgn-migration"
      OS          = each.value.os
    })
  }

  tags = merge(var.tags, { Name = "mgn-launch-${each.value.name}-${var.environment}" })
}

############################
# Post-launch SSM documents
############################

# Linux: rewrite /etc/hosts entries that point at the on-prem DB and restart
# application services. Document content lives in scripts/mgn/post_launch/.
resource "aws_ssm_document" "post_launch_linux" {
  name            = "mgn-post-launch-linux-${var.environment}"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/../../../scripts/mgn/post_launch/linux_update_config.yml")
  tags            = var.tags
}

resource "aws_ssm_document" "post_launch_windows" {
  name            = "mgn-post-launch-windows-${var.environment}"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/../../../scripts/mgn/post_launch/windows_domain_join.yml")
  tags            = var.tags
}
