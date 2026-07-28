variable "name_prefix" {
  description = "Prefix applied to all resource names/tags"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper, single point of failure). false = one NAT gateway per AZ (highly available, costs more)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every resource this module creates"
  type        = map(string)
  default     = {}
}
