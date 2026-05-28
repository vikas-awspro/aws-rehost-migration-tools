variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "staging_subnet_id" {
  description = "Private subnet used by MGN replication servers (TIG §A.3)"
  type        = string
}

variable "mgn_staging_sg_id" {
  type = string
}

variable "target_subnet_id_by_tier" {
  description = "Map from logical subnet tier (e.g. 'app', 'db') to subnet ID"
  type        = map(string)
}

variable "target_app_sg_id" {
  description = "SG applied to migrated EC2 instances"
  type        = string
}

variable "servers" {
  description = "Parsed servers inventory (list of server objects from servers.yaml)"
  type        = any
}

variable "replication_server_instance_type" {
  type    = string
  default = "t3.small"
}

variable "bandwidth_throttling_mbps" {
  description = "0 = unlimited. Set to 500 during business hours to leave room for DMS/DataSync on the DX."
  type        = number
  default     = 0
}

variable "tags" {
  type    = map(string)
  default = {}
}
