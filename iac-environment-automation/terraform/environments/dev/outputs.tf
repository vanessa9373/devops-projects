output "vpc_id" {
  value = module.vpc.vpc_id
}

output "app_instance_ids" {
  value = module.ec2.instance_ids
}

output "app_instance_private_ips" {
  value = module.ec2.private_ips
}

output "db_endpoint" {
  value = module.rds.db_endpoint
}

output "db_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}
