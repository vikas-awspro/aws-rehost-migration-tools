# DMS — pilot runbook

Implements TRD §4 acceptance criteria and TIG §B.2 step-by-step workflow.
Covers the 5 pilot databases from [inventory/databases.yaml](../inventory/databases.yaml).

| DB | Engine | Size | Target | Type |
|----|--------|------|--------|------|
| COREBANKING_DB | Oracle 19c | 4 TB | Aurora PostgreSQL 15 | Heterogeneous (SCT) |
| RISKANALYTICS_DB | SQL Server 2019 | 1.5 TB | RDS SQL Server 2019 | Homogeneous |
| REPORTING_DB | SQL Server 2016 | 800 GB | RDS SQL Server 2019 | Homogeneous |
| CUSTOMER_DB | MySQL 8.0 | 600 GB | Aurora MySQL 3.x | Homogeneous |
| PRODUCT_DB | MySQL 5.7 | 400 GB | Aurora MySQL 3.x | Homogeneous |

## Pre-flight (Week 2–3)

### Oracle (COREBANKING_DB)

```bash
sqlplus sys/...@oracle-prod-01 AS SYSDBA \
    @scripts/dms/source_prep/oracle_supplemental_logging.sql
sqlplus sys/...@oracle-prod-01 AS SYSDBA \
    @scripts/dms/source_prep/oracle_dms_user_grants.sql
```

### SQL Server (RISKANALYTICS, REPORTING)

```bash
sqlcmd -S sqlsrv-prod-01 -d RISKANALYTICS_DB -U sa -P ... \
    -i scripts/dms/source_prep/sqlserver_enable_cdc.sql
sqlcmd -S sqlsrv-prod-01 -U sa -P ... \
    -i scripts/dms/source_prep/sqlserver_dms_user_grants.sql
# Repeat for sqlsrv-prod-02 / REPORTING_DB.
```

### MySQL (CUSTOMER, PRODUCT)

```bash
mysql -h mysql-prod-01 -u root -p < scripts/dms/source_prep/mysql_binlog_check.sql
# Confirm binlog_format = ROW, log_bin = ON. If not, update my.cnf and restart.
mysql -h mysql-prod-01 -u root -p < scripts/dms/source_prep/mysql_dms_user_grants.sql
# Repeat for mysql-prod-02.
```

### SCT (COREBANKING_DB only — DMS-FR-04)

1. Install AWS SCT on the migration workstation.
2. New project → Source: Oracle 19c, Target: Amazon Aurora PostgreSQL 15.4.
3. Connect to `oracle-prod-01:1521` and the Aurora PG writer endpoint.
4. Run assessment. Save report to S3 (audit evidence).
5. Resolve all `Error` items per `docs/sct_resolution_log.md`.
6. Apply converted schema to Aurora.

**Exit criterion:** SCT assessment shows 0 Error items.

## Phase 2 — Endpoint + task creation (Week 3)

Terraform creates all 5 source endpoints, 5 target endpoints, and 5 tasks
from the inventory:

```bash
cd terraform/environments/pilot
terraform apply -target=module.dms
```

After apply, run a connection test from the DMS console for each endpoint
(or via CLI):

```bash
for ep in $(aws dms describe-endpoints --query 'Endpoints[].EndpointArn' --output text); do
    aws dms test-connection --endpoint-arn "$ep" \
        --replication-instance-arn "$(terraform output -raw dms_replication_instance)"
done
```

All endpoints must show `Status=successful` (DMS-FR-02, DMS-FR-03).

## Phase 3 — Full load (Week 4)

```bash
# Start all tasks
for task in $(terraform output -json dms_task_arns | jq -r '.[]'); do
    aws dms start-replication-task --replication-task-arn "$task" \
        --start-replication-task-type start-replication
done
```

Monitor in console: `DMS → Tasks → Table Statistics`. Expected full-load
duration:

| DB | Expected duration |
|----|-------------------|
| COREBANKING (4 TB) | ≤ 12 hours (DMS-NFR-01) |
| RISKANALYTICS (1.5 TB) | ≤ 6 hours |
| REPORTING (800 GB) | ≤ 4 hours |
| CUSTOMER (600 GB) | ≤ 3 hours |
| PRODUCT (400 GB) | ≤ 2 hours |

## Phase 4 — Validation (Week 5)

After full load completes, DMS automatically starts row-level validation.
Run the helper script:

```bash
./scripts/dms/validate.sh pilot
```

**Exit criterion (DMS-FR-08, AC-03):** validation report shows 0 pending /
0 failed / 0 suspended across all 5 tasks.

## Phase 5 — Steady-state CDC (Week 5–7)

CDC starts automatically after full load. Monitor:

- `AWS/DMS / CDCLatencyTarget` (must be < 30s sustained for 24h before cutover
  — DMS-NFR-02, AC-04)
- `AWS/DMS / CPUUtilization` on the replication instance (< 80%)
- `AWS/DMS / FreeStorageSpace` (>= 30 GB; alarm at 85% utilisation per
  DMS-NFR-03)

## Cutover (coordinated)

See [`cutover_d_day.md`](cutover_d_day.md) for the cross-stream sequence.
The DMS-specific cutover steps are:

1. Stop application writes to the source DB (write-freeze).
2. Confirm `CDCLatencyTarget = 0` for 60 seconds.
3. `aws dms stop-replication-task --replication-task-arn $TASK_ARN`.
4. Run final row-count comparison: source vs target.
5. Update application connection strings to the Aurora / RDS endpoint.
6. Smoke-test from the application.

## Rollback

DMS does **not** support reverse-direction replication mid-task. Rollback
strategy:

1. Restart application against the source DB (do not write to target after this).
2. Capture any writes that hit the target during cutover via DMS CDC running
   in the reverse direction on a new task — **only if** the engine and
   schema mapping support it.
3. For heterogeneous (Oracle → Aurora PG): rollback is one-way — abort the
   migration and restart from the next maintenance window.

## Troubleshooting

See TIG §B.5 for: connection test failures, slow full load, growing CDC lag,
validation mismatches, supplemental-logging errors, task restarts.
