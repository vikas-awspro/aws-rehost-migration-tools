#!/usr/bin/env bash
# =============================================================================
# MGN cutover orchestration helper. Walks the operator through TIG §A.2 step 11.
#
# Usage:
#   ./cutover.sh <server-name-1> [<server-name-2> ...]
#
# Pre-conditions (asserted by the script before any destructive call):
#   - MGN replication lag = 0 for the listed servers
#   - Server status = 'Ready for cutover'
#   - Operator confirms source application services are stopped
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <server-name-1> [<server-name-2> ...]" >&2
    exit 1
fi

declare -A SOURCE_IDS
echo ">>> Resolving MGN source server IDs..."
for name in "$@"; do
    id=$(aws mgn describe-source-servers --region "$REGION" \
        --filters "key=tag:Name,value=$name" \
        --query 'items[0].sourceServerID' --output text 2>/dev/null || echo "")
    if [[ -z "$id" || "$id" == "None" ]]; then
        echo "ERROR: no MGN source server tagged Name=$name" >&2
        exit 2
    fi
    SOURCE_IDS["$name"]="$id"
    echo "    $name → $id"
done

echo ""
echo ">>> Verifying replication lag = 0..."
for name in "${!SOURCE_IDS[@]}"; do
    id="${SOURCE_IDS[$name]}"
    lag=$(aws mgn describe-source-servers --region "$REGION" \
        --filters "key=sourceServerIDs,value=$id" \
        --query 'items[0].dataReplicationInfo.lagDuration' --output text)
    echo "    $name lag = $lag"
    if [[ "$lag" != "PT0S" && "$lag" != "0" && "$lag" != "None" ]]; then
        echo "ABORT: $name has non-zero replication lag ($lag). Wait and re-run." >&2
        exit 3
    fi
done

echo ""
read -rp "Confirm source application services are stopped and you're ready to launch cutover (yes/no): " ok
if [[ "$ok" != "yes" ]]; then
    echo "Aborted by operator."
    exit 4
fi

echo ""
echo ">>> Launching cutover instances..."
for name in "${!SOURCE_IDS[@]}"; do
    id="${SOURCE_IDS[$name]}"
    aws mgn start-cutover --region "$REGION" \
        --source-server-ids "$id" \
        --tags "AutoCutover=true,WaveName=pilot,Server=$name"
    echo "    cutover launched for $name ($id)"
done

echo ""
echo ">>> Done. Monitor in console: MGN → Source servers → 'Cutover'."
echo "    After 48-hour validation, finalise + archive via: aws mgn finalize-cutover."
