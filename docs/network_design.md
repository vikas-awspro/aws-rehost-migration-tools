# Network design

Implements TRD §6.

## VPC + subnet plan

| Subnet | CIDR | AZ | Purpose |
|--------|------|----|---------|
| `migration-public-a` | 10.100.1.0/24 | ap-south-1a | NAT GW only — no compute |
| `migration-public-b` | 10.100.2.0/24 | ap-south-1b | NAT GW only |
| `migration-private-a` | 10.100.10.0/24 | ap-south-1a | MGN replication servers, DMS RI, DataSync VPC endpoint |
| `migration-private-b` | 10.100.11.0/24 | ap-south-1b | MGN replication servers (HA), DMS RI standby |

Private subnets receive routes:

- `0.0.0.0/0 → NAT Gateway` (for outbound HTTPS to AWS service endpoints not
  yet behind a VPC endpoint).
- `<on-prem-CIDR> → Transit Gateway → DX Gateway → Direct Connect` (added by
  the environment when a TGW is attached).

## VPC endpoints

| Endpoint | Type | Why |
|----------|------|-----|
| `com.amazonaws.<region>.datasync` | Interface | DS-FR-07 — agent traffic stays on private network |
| `com.amazonaws.<region>.secretsmanager` | Interface | DMS endpoint credentials, DataSync SMB creds |
| `com.amazonaws.<region>.s3` | Gateway | MGN agent installer downloads, DMS task logs to S3 |

## Security groups

### `sg-mgn-staging`

| Direction | Port | Source / Dest | Why |
|-----------|------|---------------|-----|
| Ingress | TCP 1500 | On-prem CIDRs | MGN block replication from agents (NET-02) |
| Egress | TCP 443 | 0.0.0.0/0 | MGN service control plane |

### `sg-dms`

| Direction | Port | Source / Dest | Why |
|-----------|------|---------------|-----|
| Egress | TCP 1521 | On-prem CIDRs | Oracle source (NET-03) |
| Egress | TCP 1433 | On-prem CIDRs | SQL Server source (NET-04) |
| Egress | TCP 3306 | On-prem CIDRs | MySQL source (NET-05) |
| Egress | TCP 5432 | VPC CIDR | Aurora PG target (NET-06) |
| Egress | TCP 443 | 0.0.0.0/0 | Service control plane, Secrets Manager, KMS |

### `sg-datasync-endpoint`

| Direction | Port | Source / Dest | Why |
|-----------|------|---------------|-----|
| Ingress | TCP 443 | On-prem CIDRs | Agent → VPC endpoint (NET-07) |
| Egress | All | 0.0.0.0/0 | (DataSync ENIs initiate downstream calls) |

## On-prem firewall requirements

| Source → Destination | Port | Purpose |
|----------------------|------|---------|
| Source servers → MGN staging subnet | TCP 1500 | Block replication |
| Source servers → S3 endpoints | TCP 443 | Agent installer download (NET-01) |
| DMS RI ↔ Oracle / SQL Server / MySQL hosts | 1521 / 1433 / 3306 | DMS source connections |
| DataSync agent → DataSync VPC endpoint | TCP 443 | DataSync control + data plane |
| DataSync agent → NetApp ONTAP | TCP/UDP 2049 | NFS read (NET-08) |
| DataSync agent → Windows File Server | TCP 445 | SMB read (NET-09) |

## IAM (TRD §6.3 — summary)

- `MigrationAdminRole` — used by Cloud Engineering team; least-privilege
  policy covering MGN, DMS, DataSync, plus EFS / FSx, KMS, IAM read.
- `dms-vpc-role` (AWS-managed `AmazonDMSVPCManagementRole`) — DMS RI's VPC
  endpoint manipulation.
- `datasync-access` — DataSync's service-linked role for ENI management.
- `migrated-ec2-pilot` — per-environment role attached to migrated EC2s.
  Includes SSM Managed Instance Core + CloudWatch Agent Server Policy.

## KMS

A single CMK (`alias/rehost-migration-pilot`) encrypts:

- MGN staging EBS volumes (`ebs_encryption = "CUSTOM"` in the replication
  template).
- DMS replication instance storage and CloudWatch log group.
- DataSync log group.
- Target Aurora / RDS storage and the FSx / EFS file systems.
- Migrated EC2 root + data EBS volumes (via launch template).
- Secrets Manager secrets used for source/target DB credentials.

Rotation is enabled (`enable_key_rotation = true`). Key policy gives the
`MigrationAdminRole` the bare minimum for `Decrypt` and `GenerateDataKey`
during migration; no broad `kms:*`.
