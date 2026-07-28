terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "vanessa-terraform-state"
    key            = "kubernetes-microservices-deployment/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "kubernetes-microservices-deployment"
      Owner     = "Vanessa Awo"
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix  = "eks-microservices-${var.environment}"
  cluster_name = "${local.name_prefix}-cluster"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
}
