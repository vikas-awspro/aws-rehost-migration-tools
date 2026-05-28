variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.100.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnets (key => { cidr, az }) — used for NAT only"
  type = map(object({
    cidr = string
    az   = string
  }))
}

variable "private_subnets" {
  description = "Map of private subnets — host MGN staging, DMS RI, VPC endpoints"
  type = map(object({
    cidr    = string
    az      = string
    nat_key = string
  }))
}

variable "on_prem_cidrs" {
  description = "On-prem CIDRs reachable via Direct Connect / VPN — used in egress SG rules"
  type        = list(string)
  default     = []
}

variable "transit_gateway_id" {
  description = "Optional — TGW for on-prem connectivity. Routes added by environment if provided."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
