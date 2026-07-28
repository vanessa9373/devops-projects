variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "single_nat_gateway" {
  description = "Staging mirrors prod's topology but stays cost-conscious — still one shared NAT gateway, not one per AZ."
  type        = bool
  default     = true
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "allowed_ssh_cidrs" {
  type    = list(string)
  default = []
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = true
}

variable "db_backup_retention_period" {
  type    = number
  default = 7
}
