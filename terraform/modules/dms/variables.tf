variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "dms_sg_id" {
  type = string
}

variable "databases" {
  description = "Parsed inventory list. Each entry must additionally carry `target_endpoint` and `target_database_name` (populated from Aurora/RDS outputs in the env)."
  type        = any
}

variable "replication_instance_class" {
  type    = string
  default = "dms.r5.xlarge"
}

variable "engine_version" {
  type    = string
  default = "3.5.2"
}

variable "allocated_storage_gb" {
  type    = number
  default = 200
}

variable "lob_max_size_kb" {
  description = "Limited LOB mode max size (DMS-NFR-05). 64 KB default."
  type        = number
  default     = 64
}

variable "tags" {
  type    = map(string)
  default = {}
}
