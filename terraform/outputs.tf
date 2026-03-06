output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_etl_url" {
  description = "ECR repository URL for the ETL (Python) image"
  value       = module.ecr.etl_repository_url
}

output "ecr_frontend_url" {
  description = "ECR repository URL for the frontend image"
  value       = module.ecr.frontend_repository_url
}

output "ecr_backend_url" {
  description = "ECR repository URL for the backend image"
  value       = module.ecr.backend_repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC — add this to GitHub Secret AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
