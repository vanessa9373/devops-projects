variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_port" {
  description = "Port the application tier listens on"
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "Port the database tier listens on"
  type        = number
  default     = 3306
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to reach instances on port 22. Leave empty to rely on SSM Session Manager only (see modules/iam) instead of opening SSH at all."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
