# MGN — pilot runbook

Implements TRD §3 acceptance criteria (MGN-FR-01 → MGN-FR-08) and TIG §A.2
step-by-step workflow. Covers the 10 pilot servers from
[inventory/servers.yaml](../inventory/servers.yaml).

## Pre-flight gates (must pass before agent install)

| Gate | Owner | Evidence |
|------|-------|----------|
| Migration VPC + staging subnet deployed via Terraform | Cloud Eng | `terraform output vpc_id` |
| MGN service-linked role exists | Cloud Eng | `aws iam get-role --role-name AWSServiceRoleForApplicationMigrationService` |
| Replication settings template applied | Cloud Eng | `aws mgn describe-replication-configuration-templates` |
| Application Migration Service network reachability validated | Network | `nc -vz <staging-subnet-ip> 1500` from source VLAN |
| Temporary `mgn-agent-install` IAM user created | Security | Console; rotate keys after pilot |

## Phase 1 — Agent installation (Week 2)

Run on each source server. **No reboot is required.**

```bash
# Linux
sudo AWS_REGION=ap-south-1 \
     AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... \
     bash install_agent_linux.sh
```

```powershell
# Windows
$env:AWS_REGION = "ap-south-1"
$env:AWS_ACCESS_KEY_ID = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "..."
powershell -ExecutionPolicy Bypass -File .\install_agent_windows.ps1
```

After ~5 minutes each server should appear in `MGN → Source servers` with
status **Not ready** (initial sync hasn't started yet).

## Phase 2 — Initial sync (Week 2–3)

| Check | Frequency | Command |
|-------|-----------|---------|
| Sync status per server | every 4h | `aws mgn describe-source-servers` |
| Replication lag | every 1h | CloudWatch metric `ReplicationLag` |
| Replication server CPU + disk | every 1h | CloudWatch — RI instances are managed |

**Exit criterion (MGN-FR-03):** all 10 servers report `Ready for testing` and
sync lag < 1 second.

## Phase 3 — Test instance launch (Week 5)

For each server, launch a test instance from the latest replica:

```bash
aws mgn start-test --source-server-ids <id> --tags "Wave=pilot,Test=true"
```

Run application smoke tests (login, DB connection, file share mount). On
success:

```bash
aws mgn mark-as-archived  --source-server-ids <id>  # only for test cleanup
```

Test instance terminates automatically; source server status → **Ready for cutover**.

## Phase 4 — Cutover (Week 7)

**Coordinate timing with [`cutover_d_day.md`](cutover_d_day.md).**

```bash
# Pre-cutover lag check (must be 0)
aws mgn describe-source-servers \
  --filters key=sourceServerIDs,value=$ID \
  --query 'items[0].dataReplicationInfo.lagDuration'

# Launch cutover
./scripts/mgn/cutover.sh web-app-01 web-app-02 app-svc-01 ...
```

Post-cutover EC2 receives the launch-template configuration and runs the
post-launch SSM document (`mgn-post-launch-linux-pilot` or
`mgn-post-launch-windows-pilot`). The document:

- updates `/etc/app/config.properties` with the new RDS / EFS endpoints
- joins Windows hosts to the AD domain
- restarts the application service

## Phase 5 — Finalise + archive (T+48h)

```bash
aws mgn finalize-cutover --source-server-ids $ID
aws mgn change-server-life-cycle-state --source-server-id $ID --life-cycle DISCONNECTED
```

After 5 business days with no rollback request, archive the source servers
(MGN-FR-08).

## Rollback (any time before finalisation)

Cutover instances keep the source intact. To roll back:

1. Stop the cutover EC2 instance.
2. Restart application services on the source server.
3. Update DNS / load balancer to point back to the source.
4. Reconcile any data written to the cutover instance during the rollback
   window — typically minimal because cutover happens after a write freeze.

## Troubleshooting reference

See TIG §A.5 for: agent install network errors, sync stalls, lag spikes,
test instance boot failures, Windows activation post-migration.
