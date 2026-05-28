#!/usr/bin/env bash
# =============================================================================
# MGN agent installation — Linux (RHEL 7/8, CentOS 7).
# Run as root on each source server (TIG §A.2 step 4). No reboot required.
#
# Usage:
#   sudo ./install_agent_linux.sh
#
# Reads credentials from a temporary IAM user via instance metadata if the
# script is executed from a wrapper that injected them. Otherwise expects
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
INSTALLER_URL="https://aws-application-migration-service-${REGION}.s3.${REGION}.amazonaws.com/latest/linux/aws-replication-installer-init"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set." >&2
    echo "       Use a temporary access key tied to the dedicated 'mgn-agent-install'" >&2
    echo "       IAM user — never a power-user key." >&2
    exit 1
fi

# Sanity — confirm the binary OS and the kernel headers needed for the agent.
. /etc/os-release
echo "Detected: ${ID} ${VERSION_ID} — kernel $(uname -r)"

case "${ID}" in
    rhel|centos|rocky|almalinux|ol)
        sudo yum install -y wget kernel-devel-$(uname -r) kernel-headers-$(uname -r) ;;
    ubuntu|debian)
        sudo apt-get update -qq
        sudo apt-get install -y wget linux-headers-$(uname -r) ;;
    *)
        echo "WARN: unrecognised OS '${ID}'. Proceeding — agent installer will verify support." >&2 ;;
esac

# Download installer.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"
wget -q -O ./aws-replication-installer-init "${INSTALLER_URL}"
chmod +x ./aws-replication-installer-init

echo "Running MGN installer (no reboot will be triggered)..."
sudo ./aws-replication-installer-init \
    --region "${REGION}" \
    --aws-access-key-id "${AWS_ACCESS_KEY_ID}" \
    --aws-secret-access-key "${AWS_SECRET_ACCESS_KEY}" \
    --no-prompt

# Verify the agent service is running.
if systemctl is-active --quiet aws-replication-agent; then
    echo "✓ MGN agent is active on $(hostname)."
    echo "  Check the AWS console (MGN → Source servers) — this host should appear within 5 minutes."
else
    echo "✗ aws-replication-agent service is not active." >&2
    sudo systemctl status aws-replication-agent --no-pager | tail -20
    exit 2
fi
