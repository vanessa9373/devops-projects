variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "image_tag" {
  description = "ECR image tag to deploy — the pipeline passes the Git SHA here so every deploy is traceable to a commit"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the app listens on inside the container"
  type        = number
  default     = 3000
}

variable "desired_count" {
  description = "Baseline number of running tasks"
  type        = number
  default     = 2
}

variable "min_count" {
  description = "Minimum tasks for autoscaling"
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Maximum tasks for autoscaling"
  type        = number
  default     = 4
}

variable "task_cpu" {
  description = "Fargate task vCPU units (256 = .25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory in MiB"
  type        = string
  default     = "512"
}
