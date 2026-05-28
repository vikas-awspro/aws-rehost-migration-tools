################################################################################
# Migration VPC (TRD §6.1).
# 10.100.0.0/16 — public subnets for NAT, private subnets host MGN replication
# servers and the DMS replication instance. DataSync uses a VPC Interface
# Endpoint placed in the private subnets so agent traffic stays on Direct
# Connect.
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "migration-vpc-${var.environment}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "migration-igw-${var.environment}" })
}

############################
# Public subnets (NAT only)
############################

resource "aws_subnet" "public" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags = merge(var.tags, { Name = "migration-public-${each.key}-${var.environment}", Tier = "public" })
}

resource "aws_eip" "nat" {
  for_each = var.public_subnets
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "nat-eip-${each.key}-${var.environment}" })
}

resource "aws_nat_gateway" "this" {
  for_each      = var.public_subnets
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = merge(var.tags, { Name = "nat-${each.key}-${var.environment}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "rt-public-${var.environment}" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

############################
# Private subnets (MGN staging, DMS RI, DataSync VPC endpoint)
############################

resource "aws_subnet" "private" {
  for_each          = var.private_subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = merge(var.tags, { Name = "migration-private-${each.key}-${var.environment}", Tier = "private" })
}

resource "aws_route_table" "private" {
  for_each = var.private_subnets
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "rt-private-${each.key}-${var.environment}" })
}

resource "aws_route" "private_nat" {
  for_each               = var.private_subnets
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value.nat_key].id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# On-prem route — Transit Gateway carries traffic to/from the Direct Connect.
resource "aws_route" "private_on_prem" {
  for_each                = var.on_prem_cidrs == [] ? {} : var.private_subnets
  route_table_id          = aws_route_table.private[each.key].id
  destination_cidr_block  = var.on_prem_cidrs[0]
  transit_gateway_id      = var.transit_gateway_id
  count                   = 0   # placeholder — actual routes added when TGW attachment exists
}

############################
# Security groups
############################

# MGN replication servers — accept TCP 1500 from on-prem source servers (DX).
resource "aws_security_group" "mgn_staging" {
  name        = "sg-mgn-staging-${var.environment}"
  description = "MGN replication servers — accept block replication traffic from source agents"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "MGN block replication (TCP 1500) from on-prem sources"
    from_port   = 1500
    to_port     = 1500
    protocol    = "tcp"
    cidr_blocks = var.on_prem_cidrs
  }

  egress {
    description = "MGN service control plane (HTTPS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-mgn-staging-${var.environment}" })
}

# DMS replication instance — egress to source DBs (DX) and target Aurora/RDS.
resource "aws_security_group" "dms" {
  name        = "sg-dms-${var.environment}"
  description = "DMS replication instance — egress to source DBs and target Aurora/RDS"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Oracle source"
    from_port   = 1521
    to_port     = 1521
    protocol    = "tcp"
    cidr_blocks = var.on_prem_cidrs
  }

  egress {
    description = "SQL Server source"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = var.on_prem_cidrs
  }

  egress {
    description = "MySQL source"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.on_prem_cidrs
  }

  egress {
    description = "PostgreSQL/Aurora target"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "Service control plane + Secrets Manager + KMS (HTTPS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-dms-${var.environment}" })
}

# DataSync VPC endpoint — accept TCP 443 from on-prem agent IPs.
resource "aws_security_group" "datasync_endpoint" {
  name        = "sg-datasync-endpoint-${var.environment}"
  description = "DataSync VPC interface endpoint — accept HTTPS from on-prem agent"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Agent → DataSync service (HTTPS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.on_prem_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "sg-datasync-endpoint-${var.environment}" })
}

############################
# VPC endpoints — keep traffic on AWS private network
############################

# DataSync interface endpoint (DS-FR-07).
resource "aws_vpc_endpoint" "datasync" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.datasync"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.datasync_endpoint.id]
  private_dns_enabled = true
  tags = merge(var.tags, { Name = "vpce-datasync-${var.environment}" })
}

# Secrets Manager (used by all three tools for source credentials).
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.datasync_endpoint.id]
  private_dns_enabled = true
  tags = merge(var.tags, { Name = "vpce-secretsmanager-${var.environment}" })
}

# S3 gateway endpoint — used by MGN agent installer downloads and DMS S3 targets.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]
  tags              = merge(var.tags, { Name = "vpce-s3-${var.environment}" })
}
