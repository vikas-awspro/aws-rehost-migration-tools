# DataSync agent — on-prem deployment

This file documents the manual VMware OVA deployment (TIG §C.2 step 1). Two
agent VMs are deployed for redundancy (DS-NFR-03). The activation key from
each agent is captured into AWS Systems Manager Parameter Store so the
Terraform module can register the agent declaratively.

## VM specification

| Spec | Value |
|------|-------|
| vCPU | 4 |
| RAM | 32 GB |
| Disk | 80 GB thin-provisioned |
| NIC | 1× vmxnet3 on the LAN VLAN with access to NFS/SMB storage |
| Network | Outbound TCP 443 to the DataSync VPC endpoint over Direct Connect |

## Steps

1. **Download the OVA** from the AWS console:
   `DataSync → Agents → Create agent → Download VMware ESXi OVA`.

2. **Deploy in vCenter** via `Deploy OVF Template`. Power on the VM.

3. **Capture the activation key**. From a workstation that can reach the agent
   VM on TCP 80, open `http://<agent-vm-ip>/`. The page shows a one-time
   activation key. Copy it.

4. **Store the activation key in Parameter Store**:

   ```bash
   aws ssm put-parameter --region ap-south-1 \
     --name "/datasync/agent/dsync-agent-01/key" \
     --type SecureString \
     --value "<paste-key-here>" \
     --tier Standard --overwrite
   ```

5. **Repeat** for the second agent VM (`dsync-agent-02`).

6. **Trigger the Terraform apply** — the `datasync` module reads
   `/datasync/agent/<name>/key` and creates `aws_datasync_agent` resources
   with `activation_key = <ssm value>`.

## Activation script

The script [`activate_agent.sh`](activate_agent.sh) automates steps 3–5
when run from a jump host that can reach both agent VMs and the AWS API.

## Network requirements

| Source → Destination | Port | Purpose |
|---|---|---|
| Agent VM → DataSync VPC Interface Endpoint | TCP 443 | Control plane + data plane |
| Agent VM → NetApp ONTAP NFS server | TCP/UDP 2049 | NFS export read |
| Agent VM → Windows File Server | TCP 445 | SMB share read |
| Operator workstation → Agent VM | TCP 80 | One-time activation page |

Once the agent is activated, the operator's TCP 80 access can (and should) be
revoked.
