# D-Day cutover runbook — coordinated across MGN, DMS, DataSync

Implements TIG §D.2 and TRD §7 (Phase 4 — Cutover). The three migration
streams cut over within a single 4-hour maintenance window. Order matters:
**databases first** (write-freeze → DMS stop), **then file shares** (final
delta), **then servers** (MGN launch + post-launch config rewrite pointing
at the new endpoints).

| Timing | Action | Tool | Owner | Rollback action |
|--------|--------|------|-------|-----------------|
| T-7 days | MGN test launches complete; DMS CDC < 30s for 24h | MGN + DMS | Migration Lead | — |
| T-1 day | DataSync final pre-cutover daily sync runs. File count baseline captured. | DataSync | Storage Lead | — |
| T-0:00 | Window opens. User comms sent. Load balancer drained. | ALB | App Owner | Reopen LB |
| T-0:05 | Application services stopped on source servers. Write freeze on source DBs. | MGN + DMS | App + DBA | Restart services on source |
| T-0:10 | Confirm `CDCLatencyTarget = 0` for all 5 DMS tasks for 60 seconds. | DMS | DBA Lead | Resume writes; abort |
| T-0:12 | `aws dms stop-replication-task` for all 5 tasks. Record stop timestamp. | DMS | DBA Lead | `aws dms start-replication-task --start-replication-task-type resume-processing` |
| T-0:15 | Final DataSync delta sync started. Both shares. | DataSync | Storage Lead | Resume source writes |
| T-0:20 | Confirm MGN replication lag = 0 for all 10 servers. | MGN | Migration Lead | — |
| T-0:25 | MGN cutover instances launched (`./scripts/mgn/cutover.sh ...`). | MGN | Migration Lead | Stop cutover EC2; revert DNS |
| T-0:30 | DMS final row-count comparison source vs target. **Zero diff required.** | DMS | DBA Lead | Abort cutover; revert app to source DB |
| T-0:40 | DataSync delta complete. Spot-check integrity (100 files). | DataSync | Storage Lead | Application stays on source share |
| T-0:45 | MGN cutover EC2 healthy + post-launch SSM document completed. | MGN | App Owner | Stop cutover EC2 |
| T-0:50 | Application connection strings updated to Aurora / RDS / EFS / FSx endpoints. App services started on cutover EC2. | All | App Owner | Revert config; restart on source |
| T-1:00 | Smoke tests pass: login + DB read + DB write + file read. | All | App Owner | Trigger rollback |
| T-1:15 | LB reopened. Traffic restored to cutover EC2. | ALB | App Owner | Close LB |
| T-1:30 | Cutover declared successful. Hypercare begins. | — | Project Manager | — |
| T+48h | MGN cutover finalised + source servers archived. | MGN | Migration Lead | — |
| T+5d | Source DBs decommissioned (5-business-day hold). | DMS | DBA Lead | — |

## Pre-cutover gate (T-1 day)

Run before the window opens. Any FAIL aborts the cutover.

| Gate | Command | Expected |
|------|---------|----------|
| MGN lag check (all 10) | `aws mgn describe-source-servers ...` | `lagDuration = PT0S` |
| DMS validation (all 5) | `./scripts/dms/validate.sh pilot` | `0 pending / 0 failed / 0 suspended` |
| DataSync last execution | `aws datasync list-task-executions --max-results 1` | `Status = SUCCESS`, age < 24h |
| Application owner sign-off | wiki / email | Recorded |
| Rollback plan reviewed | docs | Signed |

## Rollback (any stream)

The overarching principle: **source systems remain authoritative until the
LB switches to the cutover EC2 at T-1:15.** Up to that point any stream can
roll back independently:

- **MGN rollback** — terminate the cutover EC2, restore application services
  on the source server, re-open LB to the source.
- **DMS rollback** — restart application against the source DB. Discard any
  writes to the target during the cutover window (zero diff at T-0:30
  guarantees source is the authoritative copy).
- **DataSync rollback** — re-mount the source share on the application
  server. Target EFS / FSx remains untouched.

After T-1:15 (LB switch) rollback is **expensive** but possible:

1. Capture any new writes to the target (Aurora / RDS / EFS / FSx) for
   forensic comparison.
2. Revert LB to source-connected app servers.
3. Re-open source DB for writes.
4. Re-mount source file shares.
5. Reconcile target-side writes from step 1 back into source if necessary.

## Communication checkpoints

- **T-72h:** Maintenance window comms.
- **T-4h:** Final reminder.
- **T-0:00:** Window open.
- **T-1:30:** Success (or rollback) declared.
- **T+24h:** Hypercare report.
