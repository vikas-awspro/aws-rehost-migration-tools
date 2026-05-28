# Architecture

Three migration streams running concurrently in a single Migration VPC. They
do not depend on each other, but coordinate at cutover so an application
server, its database, and its file share all switch to AWS in the same
maintenance window.

```
                            ON-PREMISE DATA CENTRE (Mumbai)
   ┌────────────────────────────────────────────────────────────────────┐
   │  Source servers (300+ — 10 in pilot)                                │
   │  Oracle / SQL Server / MySQL DBs (80+ — 5 in pilot)                 │
   │  NetApp ONTAP NFS + Windows File Server SMB (200+ TB — 2 in pilot) │
   └──────────────┬───────────────────┬─────────────────┬───────────────┘
                  │ MGN agent (TCP 1500) │ DMS (1521/1433/3306) │ DataSync agent VM (TCP 443)
                  │                    │                       │
                  └──── AWS Direct Connect 1 Gbps  ─────────────┘
                                       │
                              TGW (ap-south-1)
                                       │
   ┌───────────────────────────────────┴────────────────────────────────┐
   │           Migration VPC  10.100.0.0/16  (ap-south-1)                │
   │                                                                     │
   │  Private AZ-a 10.100.10.0/24    Private AZ-b 10.100.11.0/24         │
   │  ─────────────────────────      ─────────────────────────           │
   │  MGN Replication Servers        MGN Replication Servers (HA)         │
   │  DMS Replication Instance       DMS Replication Instance (Multi-AZ)  │
   │  DataSync VPC Endpoint          DataSync VPC Endpoint                │
   │  Secrets Manager Endpoint       Secrets Manager Endpoint             │
   │           ▲                                                          │
   │           │ S3 Gateway Endpoint                                      │
   │           ▼                                                          │
   │  s3://aws-application-migration-service-ap-south-1/...               │
   └─────────────────────────────────────────────────────────────────────┘
                                       │
   ┌───────────────────────────────────┴────────────────────────────────┐
   │       Application VPC  10.200.0.0/16  (existing — Landing Zone)     │
   │                                                                     │
   │  Public                  Private app                  Private DB    │
   │  ─────                   ───────────                  ──────────    │
   │  ALB                     EC2 (migrated by MGN)        Aurora PG     │
   │  NAT GW                                                Aurora MySQL  │
   │                                                        RDS SQL Srv  │
   │                          EFS mount target              EFS internal │
   │                          FSx for Windows interfaces                 │
   └─────────────────────────────────────────────────────────────────────┘
```

## Why these three tools, in this order

| Stream | Tool | Why |
|--------|------|-----|
| Servers | **MGN** | Block-level replication keeps RPO at 0. Cutover is "stop source, launch EC2, point DNS" — the cheapest possible RTO for a rehost. |
| Databases | **DMS** + SCT | Full-load + CDC means we can run replication for weeks and cut over with sub-30s lag — no extended outage to drain a queue. SCT handles the Oracle → Aurora PostgreSQL conversion that DMS data movement alone can't. |
| File shares | **DataSync** | Verified incremental transfers preserve POSIX/NTFS metadata. Daily syncs in the run-up to cutover shrink the final delta to < 2 hours. |

## Cutover coordination

The three tools have different cutover semantics:

- **MGN cutover** is a *launch* operation — the source server is untouched
  until the operator stops it. Rolling back is "terminate the EC2".
- **DMS cutover** is a *stop* — once stopped, target Aurora is authoritative.
  Restarting CDC is straightforward, but reverse replication is not — abort
  and start fresh from the next maintenance window.
- **DataSync cutover** is a *final delta* — the source is never modified;
  the application simply re-points to EFS / FSx.

The [coordinated D-Day runbook](../runbooks/cutover_d_day.md) orders them
**DMS-stop → DataSync-delta → MGN-launch** so the post-launch SSM document on
each migrated EC2 can rewrite config files with the new RDS / EFS endpoints
and find a target that's already authoritative for the data.

## Single source of truth — inventory YAML

[`inventory/servers.yaml`](../inventory/servers.yaml),
[`inventory/databases.yaml`](../inventory/databases.yaml), and
[`inventory/file_shares.yaml`](../inventory/file_shares.yaml) drive the
Terraform modules:

- The MGN module reads `servers.yaml` and creates one launch template per
  server with `target_instance_type`, `target_subnet`, `priority` tags.
- The DMS module reads `databases.yaml` and creates one source endpoint, one
  target endpoint, and one full-load-and-CDC task per database.
- The DataSync module reads `file_shares.yaml` and creates one source
  location, one target location, and one task per share — with schedule
  expressions for daily incremental syncs.

Adding a server / database / share to the wave is a YAML edit, validated by
the `inventory-schema` CI job before merge.

## Why DMS endpoints use Secrets Manager, not inline credentials

Endpoint usernames and passwords are managed in AWS Secrets Manager. Each
endpoint reads its secret at plan time via `data "aws_secretsmanager_secret_version"`.
This means:

1. Credentials never appear in Terraform state in a readable form (state
   stores the value, but a rotated secret stops being relevant once the
   endpoint is in service).
2. Rotation of source DB passwords is a Secrets Manager API call, not a
   Terraform apply.
3. Pilot vs prod credentials are isolated via different secret IDs.

## Why DataSync uses a VPC Interface Endpoint

DS-FR-07 mandates that DataSync traffic stays on AWS private networking. The
interface endpoint (`com.amazonaws.<region>.datasync`) routes agent ↔ service
control plane traffic through Direct Connect instead of the public internet.
The agent VM's `Service Endpoint` setting is updated to the VPC endpoint's
DNS name during activation.

## Why MGN agents authenticate with a temporary IAM user

The MGN agent installer needs an AWS access key (it cannot use the agent VM's
instance profile because it runs on-prem). We create a dedicated
`mgn-agent-install` IAM user with only `mgn:SendAgentLogsForMgn`,
`mgn:UpdateAgentSourceProperties`, etc., issue a short-lived access key, run
the installer, and rotate the key after the wave completes. The keys live in
Secrets Manager (`migration/pilot/mgn/agent-install-keys`) and are pulled by
the operator's wrapper script.
