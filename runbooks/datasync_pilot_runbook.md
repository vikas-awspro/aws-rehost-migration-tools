# DataSync — pilot runbook

Implements TRD §5 acceptance criteria and TIG §C.2 workflow. Covers the 2
pilot file shares from [inventory/file_shares.yaml](../inventory/file_shares.yaml).

| Share | Protocol | Size | File count | Target |
|-------|----------|------|------------|--------|
| /data/finreports | NFSv3 | 5 TB | 2.1 M | Amazon EFS (General Purpose) |
| \\filsrv01\customerdata | SMB 3.0 | 3 TB | 1.4 M | Amazon FSx for Windows |

## Pre-flight

| Gate | Owner | Evidence |
|------|-------|----------|
| EFS file system + mount targets in target App VPC | Storage | `aws efs describe-file-systems` |
| FSx for Windows file system joined to AD | Storage | `aws fsx describe-file-systems` |
| DataSync VPC Interface Endpoint deployed (DS-FR-07) | Cloud Eng | `terraform output vpc_id` then `aws ec2 describe-vpc-endpoints` |
| NFS export allows agent VM IPs | Storage | NetApp ONTAP export-policy review |
| SMB service account `datasync_svc` created with read access | Windows | `Get-LocalUser`, share-permission review |
| Two agent VMs deployed in vCenter | Network | `deploy_agent.md` followed |

## Phase 1 — Agent activation (Week 2)

For each agent VM:

```bash
./scripts/datasync/activate_agent.sh dsync-agent-01 10.10.50.21
./scripts/datasync/activate_agent.sh dsync-agent-02 10.10.50.22
```

The script writes the activation key into SSM Parameter Store
(`/datasync/agent/<name>/key`). After both agents are activated:

```bash
cd terraform/environments/pilot
terraform apply -target=module.datasync
```

The Terraform module registers both agents and creates the locations + tasks.

## Phase 2 — Initial full transfer (Week 3)

```bash
# Start the NFS task
aws datasync start-task-execution \
    --task-arn "$(terraform output -json datasync_task_arns | jq -r '."fs-finreports"')"

# Start the SMB task
aws datasync start-task-execution \
    --task-arn "$(terraform output -json datasync_task_arns | jq -r '."fs-customerdata"')"
```

Monitor in console: `DataSync → Tasks → Executions`. Watch:

- `FilesPrepared` / `FilesTransferred` / `FilesVerified`
- `BytesTransferred` rate
- `CloudWatch / AWS/DataSync` namespace

**Exit criteria (DS-NFR-02):**

| Share | Expected duration |
|-------|-------------------|
| NFS 5 TB | ≤ 18 hours |
| SMB 3 TB | ≤ 12 hours |

## Phase 3 — Daily incremental syncs (Week 3–6)

The task schedule in [inventory/file_shares.yaml](../inventory/file_shares.yaml)
runs both tasks at 02:00 IST daily (`cron(30 20 * * ? *)`). Verify each
execution report:

```bash
TASK_ARN="$(terraform output -json datasync_task_arns | jq -r '."fs-finreports"')"
aws datasync list-task-executions --task-arn "$TASK_ARN" --max-results 7
```

Each daily run should show `FilesTransferred < TotalFiles` (DS-FR-06).

## Phase 4 — Cutover (coordinated)

See [`cutover_d_day.md`](cutover_d_day.md). DataSync-specific steps:

1. T-1 day — last scheduled incremental sync runs at 02:00 IST.
2. T-0 — operator stops writes to the source share (read-only mount).
3. Trigger one final delta sync — expect < 2 hours (DS-NFR-05).
4. Confirm `FilesTransferred` count = source delta since last sync.
5. Run integrity spot-check on 100 random files (DS-FR-05).
6. Update application mount config: `/etc/fstab` for Linux, drive mappings
   or GPO for Windows.
7. Restart application service. Smoke-test reads + writes against EFS / FSx.
8. After 48-hour validation, disable the DataSync schedule
   (`aws datasync update-task --task-arn $ARN --schedule ScheduleExpression=""`).

## Validation

Compare file count + total bytes (TIG §C.2 step 11):

```bash
# Source — NFS
ssh netapp-01 'find /data/finreports -type f | wc -l'
ssh netapp-01 'du -sh /data/finreports'

# Target — EFS (mount from a bastion EC2)
mount -t efs <fs-id>:/ /mnt/finreports
find /mnt/finreports -type f | wc -l
du -sh /mnt/finreports
```

**Exit criterion (AC-05):** file count and total bytes match within ±0.01%
(transient files modified during transfer are acceptable; checksum-failed
files are not).

## Spot-check metadata (AC-06)

Random 100-file sample:

```bash
# Linux — POSIX permissions and mtime
find /mnt/finreports -type f | shuf | head -100 | while read f; do
    stat -c '%n  uid=%u gid=%g mode=%a mtime=%y' "$f"
done > /tmp/target-stat.txt

# Compare against source
diff <(... source equivalent ...) /tmp/target-stat.txt
```

## Rollback

DataSync transfers are one-way and non-destructive on the source. To roll
back the cutover:

1. Mount the source share back on the application server (un-do mount config
   change).
2. Source data is untouched — application resumes with no recovery needed.
3. Disable DataSync schedule until the next attempt.

## Troubleshooting

See TIG §C.4 for: agent offline, NFS mount fails, SMB auth failure, slow
transfer, verification failures, EFS mount target unreachable.
