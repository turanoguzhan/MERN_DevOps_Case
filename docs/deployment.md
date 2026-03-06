# Deployment Guide


## Prerequisites

Install the following tools before proceeding:

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2+ | https://aws.amazon.com/cli/ |
| Terraform | v1.6+ | https://developer.hashicorp.com/terraform/downloads |
| kubectl | v1.29+ | https://kubernetes.io/docs/tasks/tools/ |
| Helm | v3.13+ | https://helm.sh/docs/intro/install/ |
| Docker | v24+ | https://docs.docker.com/get-docker/ |

Run `make setup` to verify all prerequisites are installed.

---

## Step 1: AWS Account Setup


### 1.1 Configure AWS CLI

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: eu-central-1
# Default output format: json
```


### 1.2 Create Terraform State Backend (one-time)

Before running Terraform, create the S3 bucket and DynamoDB table for remote state:

```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket mern-tfstate-eu-central-1 \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Enable versioning on the bucket
aws s3api put-bucket-versioning \
  --bucket mern-tfstate-eu-central-1 \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket mern-tfstate-eu-central-1 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name mern-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1
```

---


## Step 2: Configure Terraform Variables

Create `terraform/terraform.tfvars`:

```hcl
aws_region         = "eu-central-1"
project_name       = "mern"
environment        = "production"
budget_alert_email = "your-email@example.com"
node_instance_type = "t3.medium"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 4
```

---


## Step 3: Provision AWS Infrastructure

```bash
# Initialize Terraform (downloads providers, downloads LBC policy)
make tf-init

# Preview changes (no resources created)
make tf-plan

# Apply — creates VPC, EKS, ECR, IAM roles (~15 minutes)
make tf-apply
```

Note the output values — you'll need these for GitHub Secrets:

```
eks_cluster_name      → for configure-kubectl
ecr_frontend_url      → add to GitHub Secret ECR_FRONTEND
ecr_backend_url       → add to GitHub Secret ECR_BACKEND
github_actions_role_arn → add to GitHub Secret AWS_ROLE_ARN
```

---


## Step 4: Configure kubectl

```bash
make configure-kubectl
# Verifies: kubectl cluster-info
```

---


## Step 5: Install AWS Load Balancer Controller

The ALB controller is required for the Kubernetes Ingress to create an AWS ALB:

```bash
make install-alb-controller
```

Wait for it to be ready:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```

---


## Step 6: Configure GitHub Actions Secrets

In your GitHub repository → Settings → Secrets and variables → Actions, add:

| Secret Name | Value |
|-------------|-------|
| `AWS_ROLE_ARN` | Output from `terraform output github_actions_role_arn` |
| `AWS_REGION` | `eu-central-1` |
| `ECR_FRONTEND` | Output from `terraform output ecr_frontend_url` |
| `ECR_BACKEND` | Output from `terraform output ecr_backend_url` |
| `ATLAS_URI` | Your MongoDB Atlas connection string |


### MongoDB Atlas Setup

1. Create a free cluster at https://cloud.mongodb.com
2. Add network access: Allow connections from `0.0.0.0/0` (or EKS NAT Gateway IP)
3. Create a database user with read/write access
4. Get the connection string: **Connect → Connect your application → Node.js**
   - Format: `mongodb+srv://<user>:<password>@<cluster>.mongodb.net/<dbname>?retryWrites=true&w=majority`
4. Add this as the `ATLAS_URI` GitHub Secret

---

## Step 7: Deploy the Application

### Option A: Via GitHub Actions (recommended)

Push or merge to `main` — the CD pipeline runs automatically:

```
push to main → build images → push to ECR → deploy to EKS
```

Monitor the deployment: GitHub → Actions → CD — Deploy to AWS EKS

### Option B: Manual deployment

```bash
export ECR_FRONTEND=$(cd terraform && terraform output -raw ecr_frontend_url)
export ECR_BACKEND=$(cd terraform && terraform output -raw ecr_backend_url)
export IMAGE_TAG=manual-$(date +%Y%m%d)
export ATLAS_URI="mongodb+srv://..."

# Build and push images manually
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin $ECR_FRONTEND

docker build -t $ECR_FRONTEND:$IMAGE_TAG \
  --build-arg REACT_APP_API_URL=/api mern-project/client/
docker push $ECR_FRONTEND:$IMAGE_TAG

docker build -t $ECR_BACKEND:$IMAGE_TAG mern-project/server/
docker push $ECR_BACKEND:$IMAGE_TAG

# Deploy to Kubernetes
make deploy-k8s
```

---


## Step 8: Install Monitoring

```bash
make monitoring
```

Access Grafana:
```bash
kubectl get svc -n monitoring monitoring-grafana
# Copy the EXTERNAL-IP (ALB hostname) and open in browser
# Default credentials: admin / (password set during install)
```

---


## Step 9: Access the Application

```bash
# Get the ALB URL
kubectl get ingress mern-ingress -n mern-app

# Output:
# NAME           CLASS   HOSTS   ADDRESS                                      PORTS   AGE
# mern-ingress   alb     *       xxxx.eu-central-1.elb.amazonaws.com          80      2m
```

Open `http://<ADDRESS>` in your browser.

---


## Reviewer Access

After running `terraform apply`, get reviewer credentials:

```bash
cd terraform
terraform output reviewer_access_key_id
terraform output -raw reviewer_secret_access_key
```

Share these credentials via a secure channel. The reviewer has `ReadOnlyAccess` to view:
- EKS cluster state
- ECR repositories
- CloudWatch logs
- VPC/networking resources


**Delete after review:**
```bash
cd terraform && terraform destroy -target=aws_iam_access_key.reviewer -auto-approve
```

---

## Teardown (After Review)

```bash
make teardown
```

This will:
1. Delete the `mern-app` and `monitoring` Kubernetes namespaces
2. Uninstall Helm charts (Grafana, Prometheus, ALB Controller)
3. Run `terraform destroy` to remove all AWS resources (~10 min)

---

## Troubleshooting

### Pods stuck in Pending
```bash
kubectl describe pod <pod-name> -n mern-app
# Check for: insufficient resources, image pull errors, secret missing
```

### Image pull errors (ECR auth)
```bash
# Verify node role has ECR read access
aws iam list-attached-role-policies --role-name mern-eks-node-role
```

### ALB not provisioning
```bash
kubectl get events -n mern-app
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Backend can't reach MongoDB Atlas
```bash
# Check the secret exists
kubectl get secret mern-secret -n mern-app -o yaml

# Test from a pod
kubectl run -it --rm debug --image=alpine --restart=Never -n mern-app -- \
  wget -qO- http://backend-service:5050/healthcheck/
```

### View application logs
```bash
# Backend logs
kubectl logs -l app=backend -n mern-app --follow

# Frontend logs
kubectl logs -l app=frontend -n mern-app --follow
```
