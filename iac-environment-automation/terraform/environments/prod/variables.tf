variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "single_nat_gateway" {
  description = "false = one NAT gateway per AZ. Prod pays for the HA — an AZ outage shouldn't take out every private subnet's egress."
  type        = bool
  default     = false
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "allowed_ssh_cidrs" {
  description = "Left empty deliberately — prod access is SSM Session Manager only (modules/iam), no SSH inbound rule at all."
  type        = list(string)
  default     = []
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 50
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = false
}

variable "db_backup_retention_period" {
  type    = number
  default = 30
}
