output "alb_dns_name" {
  description = "Public DNS name of the load balancer — hit this for /health, /version, /api/widgets"
  value       = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL the pipeline pushes images to"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Task definition family — used by scripts/rollback.sh to look up prior revisions"
  value       = aws_ecs_task_definition.app.family
}
