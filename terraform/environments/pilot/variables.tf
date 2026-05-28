variable "region"      { type = string  default = "ap-south-1" }
variable "environment" { type = string  default = "pilot" }

variable "on_prem_cidrs" {
  description = "CIDRs reachable over Direct Connect"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "email_subscribers" {
  type    = list(string)
  default = []
}

variable "target_application_vpc_cidr" {
  description = "CIDR of the target Application VPC where migrated EC2/RDS/EFS live."
  type        = string
  default     = "10.200.0.0/16"
}

variable "target_app_subnet_id" {
  description = "Pre-existing private app subnet ID in the application VPC."
  type        = string
}

variable "target_app_sg_id" {
  description = "Pre-existing SG to attach to migrated EC2 instances."
  type        = string
}

variable "target_db_subnet_group_name" {
  description = "Pre-existing DB subnet group in the application VPC (for Aurora/RDS targets)."
  type        = string
}

variable "target_db_sg_id" {
  type = string
}

variable "target_efs_sg_id" {
  type = string
}

variable "target_fsx_active_directory_id" {
  description = "AWS Managed Microsoft AD directory ID for FSx for Windows authentication"
  type        = string
}
