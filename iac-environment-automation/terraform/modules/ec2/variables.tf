variable "name_prefix" {
  type = string
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "subnet_ids" {
  description = "Instances are spread round-robin across these subnets"
  type        = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "iam_instance_profile" {
  type = string
}

variable "user_data" {
  description = "Bootstrap script run at first boot (see scripts/ec2-userdata.sh)"
  type        = string
  default     = null
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "tags" {
  type    = map(string)
  default = {}
}
