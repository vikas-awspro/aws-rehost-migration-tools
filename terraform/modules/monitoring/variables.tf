variable "environment" { type = string }
variable "region"      { type = string }
variable "kms_key_arn" { type = string }

variable "email_subscribers" {
  type    = list(string)
  default = []
}

variable "mgn_source_server_ids" {
  description = "MGN source server IDs (sourceServerID); populated after agents register."
  type        = list(string)
  default     = []
}

variable "dms_replication_instance_id" {
  type = string
}

variable "dms_task_ids" {
  type    = list(string)
  default = []
}

variable "dms_storage_threshold_bytes" {
  description = "Trigger storage alarm when DMS free storage falls below this. Default 30 GB."
  type        = number
  default     = 32212254720
}

variable "datasync_task_arns" {
  description = "Map share_id => task ARN"
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
