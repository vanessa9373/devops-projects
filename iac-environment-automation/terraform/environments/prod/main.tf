locals {
  name_prefix = "iac-demo-prod"
  tags        = { Environment = "prod" }
}

module "vpc" {
  source = "../../modules/vpc"

  name_prefix          = local.name_prefix
  cidr_block           = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
  single_nat_gateway   = var.single_nat_gateway
  tags                 = local.tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  name_prefix       = local.name_prefix
  vpc_id            = module.vpc.vpc_id
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  tags              = local.tags
}

module "iam" {
  source = "../../modules/iam"

  name_prefix = local.name_prefix
  tags        = local.tags
}

module "ec2" {
  source = "../../modules/ec2"

  name_prefix          = "${local.name_prefix}-app"
  instance_count       = var.instance_count
  instance_type        = var.instance_type
  subnet_ids           = module.vpc.private_subnet_ids
  security_group_ids   = [module.security_groups.app_sg_id]
  iam_instance_profile = module.iam.instance_profile_name
  user_data            = file("${path.module}/../../../scripts/ec2-userdata.sh")
  tags                 = local.tags
}

module "rds" {
  source = "../../modules/rds"

  name_prefix             = local.name_prefix
  subnet_ids              = module.vpc.private_subnet_ids
  security_group_ids      = [module.security_groups.db_sg_id]
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  multi_az                = var.db_multi_az
  deletion_protection     = var.db_deletion_protection
  skip_final_snapshot     = var.db_skip_final_snapshot
  backup_retention_period = var.db_backup_retention_period
  tags                    = local.tags
}
