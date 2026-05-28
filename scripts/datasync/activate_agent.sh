#!/usr/bin/env bash
# =============================================================================
# Fetches the DataSync activation key from a deployed agent VM and stores it in
# SSM Parameter Store so the Terraform `datasync` module can register the agent.
#
# Usage:
#   ./activate_agent.sh <agent-name> <agent-vm-ip>
#
# Pre-conditions:
#   - Agent VM is deployed and powered on (see deploy_agent.md)
#   - Workstation can reach agent VM on TCP 80
#   - AWS_REGION + valid AWS credentials are exported
# =============================================================================
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <agent-name> <agent-vm-ip>" >&2
    echo "   eg: $0 dsync-agent-01 10.10.50.21" >&2
    exit 1
fi

NAME="$1"
IP="$2"
REGION="${AWS_REGION:-ap-south-1}"
SSM_PATH="/datasync/agent/${NAME}/key"

# Fetch the key from the agent's local activation page (HTTP 302 → /getkey?...).
KEY=$(curl -fsSL --max-time 10 "http://${IP}/getkey?gatewayType=SYNC&activationRegion=${REGION}" \
     | grep -oE 'activationKey=[A-Z0-9-]+' \
     | head -1 \
     | cut -d= -f2)

if [[ -z "$KEY" ]]; then
    echo "ERROR: could not extract activation key from agent at $IP." >&2
    echo "Check that the agent VM is powered on and reachable on TCP 80." >&2
    exit 2
fi

echo "Retrieved activation key from $IP: ${KEY:0:8}... (truncated)"

aws ssm put-parameter --region "$REGION" \
    --name "$SSM_PATH" \
    --type SecureString \
    --value "$KEY" \
    --tier Standard \
    --overwrite >/dev/null

echo "✓ Stored at $SSM_PATH. Next: cd terraform/environments/pilot && terraform apply"
