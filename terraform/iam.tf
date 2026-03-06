# GitHub Actions OIDC Provider — enables keyless authentication from GitHub Actions
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub Actions OIDC thumbprint (stable value)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# IAM Role that GitHub Actions assumes via OIDC
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to pushes/PRs on main branch of this repo
            # Update <YOUR_GITHUB_USERNAME> with your actual GitHub username
            "token.actions.githubusercontent.com:sub" = "repo:*:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

# Policy for GitHub Actions: push to ECR and deploy to EKS
resource "aws_iam_policy" "github_actions" {
  name        = "${var.project_name}-github-actions-policy"
  description = "Allows GitHub Actions to push to ECR and deploy to EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

# Read-only IAM user for reviewers to inspect the deployment
resource "aws_iam_user" "reviewer" {
  name = "${var.project_name}-reviewer"
  path = "/"
}

resource "aws_iam_user_policy_attachment" "reviewer_readonly" {
  user       = aws_iam_user.reviewer.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_access_key" "reviewer" {
  user = aws_iam_user.reviewer.name
}

output "reviewer_access_key_id" {
  description = "Reviewer IAM access key ID — share securely, delete after review"
  value       = aws_iam_access_key.reviewer.id
  sensitive   = true
}

output "reviewer_secret_access_key" {
  description = "Reviewer IAM secret access key — share securely, delete after review"
  value       = aws_iam_access_key.reviewer.secret
  sensitive   = true
}
