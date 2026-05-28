variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "private_subnet_arns" {
  description = "Subnet ARNs the DataSync agents register against"
  type        = list(string)
}

variable "datasync_vpc_endpoint_id" {
  description = "Interface endpoint ID (com.amazonaws.<region>.datasync)"
  type        = string
}

variable "datasync_endpoint_sg_arn" {
  type = string
}

variable "agent_names" {
  description = "Names of the on-prem agent VMs whose activation keys are already in SSM Parameter Store"
  type        = list(string)
  default     = ["dsync-agent-01", "dsync-agent-02"]
}

variable "file_shares" {
  description = "Parsed inventory list (with protocol-specific fields)"
  type        = any
}

variable "target_locations" {
  description = "Map of share_id => DataSync target location ARN (EFS or FSx, created in the env)"
  type        = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
