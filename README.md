# AWS Rehost Migration Tools

**Tooling, automation, and runbooks for a coordinated three-stream lift-and-shift to AWS — MGN for 300+ servers, DMS for 80+ databases (Oracle/SQL Server/MySQL), DataSync for 200+ TB of NFS and SMB file shares. This repo delivers Phase 1: tooling setup and pilot migration of 10 servers, 5 databases, and 2 file shares for a financial services customer, delivered as part of an AWS Professional Services engagement.**

![AWS MGN](https://img.shields.io/badge/AWS-Application%20Migration%20Service-FF9900?logo=amazonaws&logoColor=white)
![AWS DMS](https://img.shields.io/badge/AWS-DMS-FF9900?logo=amazonaws&logoColor=white)
![AWS DataSync](https://img.shields.io/badge/AWS-DataSync-FF9900?logo=amazonaws&logoColor=white)
![AWS SCT](https://img.shields.io/badge/AWS-SCT-FF9900?logo=amazonaws&logoColor=white)
![Aurora](https://img.shields.io/badge/Aurora-PostgreSQL%20%2B%20MySQL-336791?logo=postgresql&logoColor=white)
![EFS / FSx](https://img.shields.io/badge/Storage-EFS%20%2B%20FSx-3F8624)
![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.6-7B42BC?logo=terraform&logoColor=white)
![Direct Connect](https://img.shields.io/badge/Network-Direct%20Connect%201%20Gbps-232F3E?logo=amazonaws&logoColor=white)
![Region](https://img.shields.io/badge/Region-ap--south--1-232F3E?logo=amazonaws&logoColor=white)
![Compliance](https://img.shields.io/badge/Auth-OIDC%20%2B%20KMS%20CMK-DD344C)

---

## Architecture

```
   ON-PREMISE DATA CENTRE (Mumbai)
   ┌─────────────────────────────────────────────────────────────┐
   │  300+ servers · 80+ DBs · 200+ TB file shares               │
   │  (pilot wave: 10 servers, 5 DBs, 2 shares)                  │
   └─────────────────────────────────────────────────────────────┘
           │ MGN agent (1500)    │ DMS (1521/1433/3306)   │ DataSync (443)
           └───── AWS Direct Connect 1 Gbps ──────────────────────┘
                                  │
                          Migration VPC (ap-south-1)
                          10.100.0.0/16
                          ├── MGN Replication Servers   (Multi-AZ)
                          ├── DMS Replication Instance  (Multi-AZ, dms.r5.xlarge)
                          ├── DataSync VPC Endpoint     (Interface)
                          ├── Secrets Manager Endpoint
                          └── S3 Gateway Endpoint
                                  │
                          Target Application VPC (ap-south-1)
                          10.200.0.0/16
                          ├── EC2 (migrated by MGN)
                          ├── Aurora PG + Aurora MySQL + RDS SQL Server
                          └── EFS + FSx for Windows
```

Three streams run in parallel during the migration wave and coordinate at
cutover — see [`runbooks/cutover_d_day.md`](runbooks/cutover_d_day.md) for the
T-7d → T+5d sequence that switches application servers, databases, and file
shares to AWS in a single 4-hour maintenance window.

---

## What I designed vs. what I built

| What I designed (TRD + TIG) | What I built (this repo) |
|---|---|
| Three migration streams (MGN, DMS, DataSync) running concurrently in a shared Migration VPC, all traffic over Direct Connect via VPC endpoints — no public-internet hops for replication data. | [`terraform/modules/network`](terraform/modules/network/) provisions the VPC, private subnets across two AZs, and interface endpoints for DataSync + Secrets Manager + gateway endpoint for S3. SGs scoped to on-prem CIDRs and target VPC only. |
| A single inventory file per stream that drives Terraform — adding a server / database / file share to the wave is a YAML edit, not a Terraform edit, and is validated by CI before merge. | [`inventory/servers.yaml`](inventory/servers.yaml) (10 entries), [`inventory/databases.yaml`](inventory/databases.yaml) (5 entries), [`inventory/file_shares.yaml`](inventory/file_shares.yaml) (2 entries). [`scripts/_ci/validate_inventory.py`](scripts/_ci/validate_inventory.py) enforces a JSON Schema in CI. |
| MGN replication settings hardened by default — staging subnet private, no public IP, CMK encryption, GP3 staging disks, bandwidth throttling during business hours. | [`terraform/modules/mgn`](terraform/modules/mgn/) creates the replication template, per-server launch templates (IMDSv2 required, GP3 root + data, KMS CMK encryption), the migrated-EC2 IAM instance profile with SSM + CloudWatch Agent, and post-launch SSM documents for Linux config rewrite and Windows AD domain join. |
| DMS replication instance Multi-AZ in private subnets, full-load-and-CDC tasks per database, row-level validation, SSL verify-full endpoints, credentials in Secrets Manager. | [`terraform/modules/dms`](terraform/modules/dms/) reads the inventory, creates the Multi-AZ RI, one source + one target endpoint per DB (reading creds from Secrets Manager at plan time), and one task with the spec-compliant `replication_task_settings` JSON (LOB Limited 64KB, validation on, FailureMaxCount=0). |
| Source-side preparation scripts for every supported engine — Oracle supplemental logging + DMS user grants, SQL Server MS-CDC enablement, MySQL binlog verification. | [`scripts/dms/source_prep/`](scripts/dms/source_prep/) — six SQL files covering Oracle / SQL Server / MySQL prep and DMS user creation. Plus [`scripts/dms/validate.sh`](scripts/dms/validate.sh) — aggregates DMS validation counts across all tasks and exits non-zero on any pending/failed/suspended row. |
| Two redundant on-prem DataSync agent VMs, activation keys captured into SSM Parameter Store so Terraform can register the agents declaratively, tasks with daily incremental schedules. | [`terraform/modules/datasync`](terraform/modules/datasync/) reads `/datasync/agent/<name>/key` from SSM; [`scripts/datasync/activate_agent.sh`](scripts/datasync/activate_agent.sh) automates the key capture; tasks created with the spec-compliant `verify_mode`, posix permissions, and cron schedule from the inventory. |
| Cross-stream cutover orchestration — databases stop first (write-freeze + DMS stop), then DataSync runs its final delta, then MGN launches the cutover EC2s pointing at the now-authoritative target endpoints. | [`runbooks/cutover_d_day.md`](runbooks/cutover_d_day.md) — single coordinated runbook with timing, owner, and rollback action per step. Per-stream details split into [`mgn_pilot_runbook.md`](runbooks/mgn_pilot_runbook.md), [`dms_pilot_runbook.md`](runbooks/dms_pilot_runbook.md), [`datasync_pilot_runbook.md`](runbooks/datasync_pilot_runbook.md). |
| Single CloudWatch dashboard covering all three streams (MGN lag, DMS CDC lag, full-load throughput, validation counts, DataSync bytes transferred) plus an SNS alarm topic for paging. | [`terraform/modules/monitoring`](terraform/modules/monitoring/) provisions the SNS topic, the dashboard from [`dashboard.json.tpl`](terraform/modules/monitoring/dashboard.json.tpl) (uses CloudWatch metric `SEARCH` expressions so new tasks auto-appear), and threshold alarms tied to the TRD NFR targets (MGN lag 60s, DMS CDC 30s, DMS storage 85%, DataSync verify failures). |
| OIDC-authenticated CI/CD — PR-time `terraform plan` posted as a sticky comment; apply gated by protected GitHub Environment requiring reviewer approval. | [`.github/workflows/terraform-plan.yml`](.github/workflows/terraform-plan.yml) (PR plan + tflint), [`terraform-apply.yml`](.github/workflows/terraform-apply.yml) (push-to-main, env-gated), [`script-checks.yml`](.github/workflows/script-checks.yml) (ShellCheck + yamllint + inventory schema validation). Zero static AWS access keys. |

---

## Source documents

The TRD is the customer-issued requirements artifact. The TIG is the
implementation guide I authored as the delivery partner.

| Document | Purpose |
|---|---|
| [`docs/Migration_TRD_Customer_Requirements.docx`](docs/Migration_TRD_Customer_Requirements.docx) | Programme objectives, pilot scope, per-stream functional + non-functional requirements (MGN-FR-01 → DS-NFR-05), acceptance criteria, phase plan |
| [`docs/AWS_Migration_Tooling_Technical_Implementation_Guide.docx`](docs/AWS_Migration_Tooling_Technical_Implementation_Guide.docx) | How MGN / DMS / DataSync work, step-by-step setup, recommended settings, troubleshooting tables, coordinated cutover sequence |
| [`docs/architecture.md`](docs/architecture.md) | ASCII architecture, why each tool, single-source-of-truth inventory, cutover ordering |
| [`docs/network_design.md`](docs/network_design.md) | VPC + subnet plan, SG rules per tool, on-prem firewall asks, KMS scope |
| [`runbooks/`](runbooks/) | Four runbooks — three per-tool, one coordinated D-Day |

---

## Key decisions

A handful of non-obvious calls were made early — these shaped the rest of the
design and are worth flagging to anyone picking the repo up cold.

- **One Migration VPC, three tools — not three VPCs.** Each AWS migration
  service can live in its own VPC, but doing so multiplies VPC endpoints,
  Direct Connect routes, and security-group review burden by three. A single
  Migration VPC with carefully scoped SGs (`sg-mgn-staging`, `sg-dms`,
  `sg-datasync-endpoint`) keeps the network surface area tight, lets the
  three tools share Direct Connect bandwidth, and means one CloudWatch
  dashboard captures the whole programme.

- **Inventory YAML drives Terraform, not Terraform drives inventory.** The
  cheap version of this repo would be 17 hand-written Terraform resources
  (one per pilot workload). Instead, three YAML files describe the wave, a
  CI step validates them against a JSON schema, and the Terraform modules
  `for_each` over the parsed lists. Adding a server to the next wave is a
  one-line YAML edit reviewed in a PR — no Terraform refactor required, and
  the schema validator catches the most common errors (mis-spelled
  `target_engine`, missing `priority`) before plan even runs.

- **DataSync activation keys go through SSM Parameter Store, not Terraform
  variables.** DataSync agents are deployed manually on-prem (a VMware OVA
  is not Terraform-friendly). The activation key is short-lived and unique
  per VM. Storing it as a `SecureString` SSM parameter
  (`/datasync/agent/<name>/key`) means the operator captures it once with a
  tiny helper script, Terraform reads it declaratively, and there's no
  awkward `-var=` invocation or risk of the key landing in shell history.

- **DMS endpoint credentials read from Secrets Manager at *plan* time, not
  passed as variables.** Both source and target DB credentials are stored in
  Secrets Manager (`migration/pilot/source/<engine>/<db>` and
  `migration/pilot/target/<engine>/<db>`). The DMS module reads them via
  `data "aws_secretsmanager_secret_version"`. Rotating a source DB password
  becomes a Secrets Manager operation; the DMS endpoint picks up the new
  value on the next apply. Terraform state still holds the resolved value,
  but the *source of truth* is Secrets Manager — and rotation doesn't need a
  Terraform change.

- **Coordinated cutover: DMS stops first, MGN launches last.** The temptation
  is to do all three cutovers in parallel because the streams are
  independent. But each migrated application server runs a post-launch SSM
  document that rewrites its config file with the *new* RDS / EFS endpoints —
  which means those endpoints must already be authoritative when the EC2
  boots. So the runbook orders the cutover as **DB write-freeze + DMS stop →
  DataSync final delta → MGN cutover launch**. Three minutes of additional
  outage on the application is worth not having to re-run a post-launch fix
  pass.

- **MGN agents authenticate with a temporary IAM user, not the source server's
  identity.** Source servers are on-prem and have no AWS identity. We create a
  dedicated `mgn-agent-install` IAM user with the *minimum* MGN install
  permissions, issue a short-lived access key, run the installer, and rotate
  the key after the wave completes. The keys live in Secrets Manager; the
  installer wrapper script (`install_agent_linux.sh` / `install_agent_windows.ps1`)
  reads them via environment variables and never persists them to disk.

---

## Acceptance criteria coverage

| AC | Stream | Requirement | Covered by |
|----|--------|-------------|------------|
| AC-01 | MGN | All 10 servers running on EC2 with zero P1 errors for 48h | [`runbooks/mgn_pilot_runbook.md`](runbooks/mgn_pilot_runbook.md) + post-launch SSM docs |
| AC-02 | MGN | Cutover window ≤ 60 min per server | [`scripts/mgn/cutover.sh`](scripts/mgn/cutover.sh) — pre-flight lag check + parallel launch |
| AC-03 | DMS | Zero data loss — 0 mismatched rows on all 5 DBs | [`scripts/dms/validate.sh`](scripts/dms/validate.sh) — fail-non-zero on any non-zero count |
| AC-04 | DMS | CDC lag < 30s sustained 24h pre-cutover | `cdc-lag` alarm in [`terraform/modules/monitoring`](terraform/modules/monitoring/main.tf) |
| AC-05 | DataSync | File count + total bytes match source for both shares | [`runbooks/datasync_pilot_runbook.md`](runbooks/datasync_pilot_runbook.md) phase 5 verification |
| AC-06 | DataSync | File metadata preserved — 100-file spot check | DataSync task `posix_permissions=PRESERVE`, `mtime=PRESERVE`, `smb_acls=BEST_EFFORT` |
| AC-07 | All | Zero critical Security Hub findings on migrated infra | KMS CMK on all storage, IMDSv2 enforced, no public IPs, private staging subnet |
| AC-08 | All | Migration Hub reflects real-time status; final wave report | Out of repo scope — Migration Hub is account-level config; CloudWatch dashboard covers operational view |

---

## Repository layout

```
aws-rehost-migration-tools/
├── inventory/                      Drives Terraform — edit YAML, not .tf
│   ├── servers.yaml                10 server definitions
│   ├── databases.yaml              5 database definitions
│   └── file_shares.yaml            2 file share definitions
├── terraform/
│   ├── modules/
│   │   ├── network/                VPC, subnets, SGs, VPC endpoints
│   │   ├── mgn/                    Replication template, per-server launch templates,
│   │   │                            migrated-EC2 instance profile, post-launch SSM docs
│   │   ├── dms/                    RI, endpoints, tasks driven by inventory
│   │   ├── datasync/               Agents (from SSM keys), locations, tasks
│   │   └── monitoring/             Dashboard, alarms, SNS
│   └── environments/
│       └── pilot/                  Aurora + RDS + EFS + FSx targets + module wiring
├── scripts/
│   ├── mgn/
│   │   ├── install_agent_linux.sh  Wrapper for RHEL/CentOS source servers
│   │   ├── install_agent_windows.ps1   Wrapper for Windows source servers
│   │   ├── post_launch/            SSM document YAML — Linux config + Windows domain join
│   │   └── cutover.sh              Pre-flight lag check + parallel cutover launch
│   ├── dms/
│   │   ├── source_prep/            Oracle, SQL Server, MySQL preparation SQL
│   │   └── validate.sh             Aggregate validation across all tasks
│   ├── datasync/
│   │   ├── deploy_agent.md         OVA deployment notes
│   │   └── activate_agent.sh       Captures activation key into SSM Parameter Store
│   └── _ci/
│       └── validate_inventory.py   JSON Schema for the three inventory files
├── runbooks/
│   ├── mgn_pilot_runbook.md
│   ├── dms_pilot_runbook.md
│   ├── datasync_pilot_runbook.md
│   └── cutover_d_day.md            Coordinated cross-stream cutover
├── docs/                           TRD + TIG (docx) + architecture + network design
└── .github/workflows/              plan + apply + script-checks (OIDC, no static keys)
```

---

## Quick start

<details>
<summary>30-second overview — full walk-through in the runbooks</summary>

```bash
# 1. Bootstrap state backend (one-time, in the migration account)
aws s3api create-bucket --bucket rehost-migration-tfstate-pilot \
  --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
aws dynamodb create-table --table-name rehost-migration-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region ap-south-1

# 2. Populate Secrets Manager — source + target DB credentials, SMB service
# account, MGN install IAM user keys, domain-join account.
for s in source/oracle/corebanking target/aurora-pg/corebanking \
         source/sqlserver/riskanalytics target/rds-sqlserver/riskanalytics \
         ... ; do
  aws secretsmanager create-secret --name "migration/pilot/$s" \
      --secret-string '{"username":"...","password":"..."}'
done

# 3. Deploy DataSync agents on-prem (see scripts/datasync/deploy_agent.md),
#    then for each agent VM:
./scripts/datasync/activate_agent.sh dsync-agent-01 10.10.50.21
./scripts/datasync/activate_agent.sh dsync-agent-02 10.10.50.22

# 4. Apply infrastructure
cd terraform/environments/pilot
terraform init
terraform plan -out=pilot.tfplan
terraform apply pilot.tfplan

# 5. Source preparation
sqlplus sys@oracle-prod-01 AS SYSDBA @scripts/dms/source_prep/oracle_supplemental_logging.sql
sqlcmd -S sqlsrv-prod-01 -i scripts/dms/source_prep/sqlserver_enable_cdc.sql
mysql -h mysql-prod-01 -e 'source scripts/dms/source_prep/mysql_binlog_check.sql'

# 6. Install MGN agents on the 10 pilot servers (see runbooks/mgn_pilot_runbook.md)

# 7. Start DMS tasks
for t in $(terraform output -json dms_task_arns | jq -r 'values[]'); do
  aws dms start-replication-task --replication-task-arn "$t" \
    --start-replication-task-type start-replication
done

# 8. Trigger initial DataSync transfers (subsequent transfers run daily via schedule)
for t in $(terraform output -json datasync_task_arns | jq -r 'values[]'); do
  aws datasync start-task-execution --task-arn "$t"
done

# 9. Validate
./scripts/dms/validate.sh pilot

# 10. Cutover — follow runbooks/cutover_d_day.md
```

</details>

---

## License

[MIT](LICENSE).

---

## Author

**Vikas Jain** — Senior Cloud Architect
Pilot migration patterns from delivering server / database / file-share rehosts as an AWS Professional Services partner. Designed, built, and documented end-to-end.
