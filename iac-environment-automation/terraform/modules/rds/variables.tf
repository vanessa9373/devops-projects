variable "name_prefix" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group — RDS should never sit in a public subnet"
  type        = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "engine" {
  type    = string
  default = "mysql"
}

variable "engine_version" {
  type    = string
  default = "8.0"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "username" {
  type    = string
  default = "admin"
}

variable "multi_az" {
  description = "Multi-AZ standby for automatic failover. Enable for staging/prod, not dev."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block accidental terraform destroy / console deletion. Enable for prod."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip taking a final snapshot on destroy. Fine for dev, should be false for prod."
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
