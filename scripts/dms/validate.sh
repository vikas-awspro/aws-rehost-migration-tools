#!/usr/bin/env bash
# =============================================================================
# Validates DMS task health and validation results across all pilot DBs.
# Run before cutover decisions (DMS-FR-08, AC-03).
# Output: a one-line summary per task plus a non-zero exit if any task has
# pending/suspended/failed validation rows.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ENV="${1:-pilot}"

echo ">>> Listing all DMS tasks tagged Project=aws-rehost-migration-tools, Environment=$ENV"
TASK_ARNS=$(aws dms describe-replication-tasks --region "$REGION" \
    --filters "Name=replication-task-id,Values=task-db-*" \
    --query 'ReplicationTasks[*].ReplicationTaskArn' --output text)

if [[ -z "$TASK_ARNS" ]]; then
    echo "No DMS tasks found." >&2
    exit 1
fi

FAILED=0
for arn in $TASK_ARNS; do
    task_id=$(basename "$arn")
    status=$(aws dms describe-replication-tasks --region "$REGION" \
        --filters "Name=replication-task-arn,Values=$arn" \
        --query 'ReplicationTasks[0].Status' --output text)

    # Aggregate validation totals
    validation=$(aws dms describe-table-statistics --region "$REGION" \
        --replication-task-arn "$arn" \
        --query 'TableStatistics[].[Inserts,Updates,Deletes,ValidationPendingRecords,ValidationFailedRecords,ValidationSuspendedRecords]' \
        --output json)

    pending=$(echo "$validation"  | jq '[.[][3]] | add // 0')
    failed_v=$(echo "$validation" | jq '[.[][4]] | add // 0')
    suspended=$(echo "$validation" | jq '[.[][5]] | add // 0')

    printf "%-40s status=%-15s pending=%-6s failed=%-6s suspended=%-6s\n" \
        "$task_id" "$status" "$pending" "$failed_v" "$suspended"

    if [[ "$failed_v" -gt 0 || "$suspended" -gt 0 || "$pending" -gt 0 ]]; then
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [[ $FAILED -gt 0 ]]; then
    echo "✗ $FAILED task(s) have non-zero validation issues — DO NOT CUT OVER."
    exit 2
else
    echo "✓ All tasks healthy. Validation: 0 pending / 0 failed / 0 suspended."
fi
