# Context

A pre-built MERN stack application (React frontend + Express.js backend + MongoDB Atlas) needs a complete DevOps layer added on top of it. The application code is ready but has zero DevOps infrastructure. 
The project goal is to containerize the applications, orchestrate them with Kubernetes on AWS EKS, provide a GitHub Actions CI/CD pipeline, add logging/alerting via Prometheus + Grafana, and provision all cloud infrastructure via Terraform. 
The all implementations should followDevOps best practices.

# Tech Stack:

## Cloud Provider: AWS (eu-central-1)
## Kubernetes: Amazon EKS 
## Container Registry: Amazon ECR
## CI/CD: GitHub Actions (OIDC-based keyless AWS auth)
## Database: MongoDB Atlas (managed, external)
## IaC: Terraform — full stack (VPC + EKS + ECR + IAM)
## Monitoring: kube-prometheus-stack (Prometheus + Grafana + Alertmanager(ClockWatch) )

# Step-by-Step Implementation
## Step 1 — Dockerize
mern-project/client/Dockerfile (multi-stage):
Stage 1 (builder): node:20-alpine
  - WORKDIR /app
  - COPY package*.json && npm ci
  - COPY src/ public/ && npm run build

Stage 2 (runtime): nginx:alpine
  - COPY --from=builder /app/build /usr/share/nginx/html
  - COPY nginx.conf /etc/nginx/conf.d/default.conf
  - EXPOSE 80
  
mern-project/client/nginx.conf:
   - Serve React SPA with try_files $uri $uri/ /index.html
   - Proxy /api/ → http://backend-service:5050/

mern-project/server/Dockerfile:
  - FROM node:20-alpine
  - WORKDIR /app
  - COPY package*.json ./
  - RUN npm ci --only=production
  - COPY . .
  - EXPOSE 5050
  - CMD ["node", "server.mjs"]

.dockerignore files for both: node_modules, .env*, cypress/

mern-project/docker-compose.yml:

  - client: build from ./client, port 3000→80, depends_on server
  - server: build from ./server, port 5050, env ATLAS_URI from .env
  - Healthchecks on both using /healthcheck/


## Step 2 — Terraform Infrastructure (Full Stack)
Architecture:

VPC: 10.0.0.0/16, 2 AZs
   2 public subnets (10.0.1.0/24, 10.0.2.0/24) — NAT GW, ALB
   2 private subnets (10.0.3.0/24, 10.0.4.0/24) — EKS worker nodes


Internet Gateway → public subnets
- NAT Gateway (in public subnet) → private subnets egress
- EKS Cluster (Kubernetes 1.29) on private subnets
   - Managed node group: t3.medium, min 1 / desired 2 / max 4 nodes
   - Add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI driver
- ECR repos: mern-frontend, mern-backend (image scanning enabled)
- IAM:
   - EKS cluster role (AmazonEKSClusterPolicy)
   - EKS node role (AmazonEKSWorkerNodePolicy, AmazonEC2ContainerRegistryReadOnly, AmazonEKS_CNI_Policy)
   - GitHub Actions OIDC role (trust policy for repo:<owner>/MERN_DevOps_Case:ref:refs/heads/main)
      - Permissions: ecr:*, eks:DescribeCluster, eks:UpdateNodegroupConfig
- AWS Load Balancer Controller (deployed via Helm after EKS creation)

Terraform state backend (S3 + DynamoDB locking):
`hclterraform {
  backend "s3" {
    bucket         = "mern-tfstate-<random>"
    key            = "mern/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "mern-tfstate-lock"
    encrypt        = true
  }
}`
outputs.tf: EKS cluster name, ECR frontend URL, ECR backend URL, VPC ID

## Step 3 — Kubernetes Manifests
k8s/namespace.yaml: namespace mern-app
k8s/secret.yaml (template — CI/CD fills actual value):
`stringData:
  ATLAS_URI: "$(ATLAS_URI)"  # replaced by envsubst in CD pipeline`

k8s/backend/deployment.yaml:
Image: <ECR_BACKEND>:$IMAGE_TAG
envFrom.secretRef: name: mern-secret
Liveness: GET /healthcheck/ after 30s
Readiness: GET /healthcheck/ after 10s
Resources: requests: cpu:100m mem:128Mi, limits: cpu:250m mem:256Mi

k8s/frontend/deployment.yaml:
Image: <ECR_FRONTEND>:$IMAGE_TAG
Resources: requests: cpu:50m mem:64Mi, limits: cpu:100m mem:128Mi

k8s/ingress.yaml (AWS ALB):
yamlannotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
rules:
  - http.paths:
      - path: /api   → backend-service:5050
      - path: /      → frontend-service:80

Server routing: The Express server exposes /healthcheck/ and /record/, not /api/*. 
The Nginx config in the frontend container will strip /api prefix when proxying to backend, OR Ingress path rewriting will handle this.

## Step 4 — GitHub Actions CI/CD
.github/workflows/ci.yml (on: pull_request to main):
`jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - Checkout
      - Setup Node 20
      - npm ci (server) + syntax check
      - npm ci (client) + npm run build
      - Run Cypress headless (with cy:run, using built client)
  docker-build:
    steps:
      - docker build client/ (verify Dockerfile)
      - docker build server/ (verify Dockerfile)`

.github/workflows/cd.yml (on: push to main):
`permissions:
  id-token: write   # OIDC
  contents: read

jobs:
  build-push:
    steps:
      - Configure AWS credentials (OIDC, role: GitHubActionsRole ARN from Terraform output)
      - Login to ECR (aws ecr get-login-password | docker login)
      - Build + tag images: ${{ github.sha }} and latest
      - Push to ECR (frontend + backend)

  deploy:
    needs: build-push
    steps:
      - Configure AWS credentials (OIDC)
      - Update kubeconfig (aws eks update-kubeconfig --name mern-cluster)
      - Create/update K8s secret: kubectl create secret generic mern-secret
          --from-literal=ATLAS_URI=${{ secrets.ATLAS_URI }} --dry-run=client | kubectl apply -f -
      - Substitute IMAGE_TAG in manifests: IMAGE_TAG=${{ github.sha }} envsubst
      - kubectl apply -f k8s/
      - kubectl rollout status deployment/backend -n mern-app
      - kubectl rollout status deployment/frontend -n mern-app`

Required GitHub Secrets:
ATLAS_URI: MongoDB Atlas connection string
AWS_ROLE_ARN: GitHub Actions OIDC role ARN (from Terraform output)
AWS_REGION: eu-central-1
ECR_FRONTEND: ECR frontend repo URL
ECR_BACKEND: ECR backend repo URL

## Step 5 — Monitoring & Alerting
Install via Helm in CD or Makefile:
`helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/prometheus-values.yaml
```

**`monitoring/prometheus-values.yaml`**:
- Grafana: `adminPassword` from K8s secret, service type `LoadBalancer`
- Prometheus: 15d retention
- Enable: nodeExporter, kubeStateMetrics, alertmanager

**`monitoring/alert-rules.yaml`** (PrometheusRule):
- `PodCrashLooping`: `kube_pod_container_status_restarts_total > 3` for 5m
- `HighHTTPErrorRate`: `rate(http_requests_total{status=~"5.."}[5m]) > 0.05`
- `PodNotReady`: pod not ready for 5m
- `NodeHighCPU`: node CPU usage > 80% for 10m

**Add `prom-client` to Express server** (`mern-project/server/`):
- Add `prom-client` package
- Add `/metrics` endpoint exposing default Node.js metrics
`
---

### Step 6 — Documentation & Makefile

**`docs/architecture.md`**: Mermaid diagram showing:
```
GitHub → GitHub Actions → ECR → EKS (frontend pods + backend pods) → MongoDB Atlas
                                     ↑
                               ALB Ingress
                                     ↑
                               Internet users

docs/deployment.md: Prerequisites, AWS account setup, Terraform apply steps, CI/CD config, monitoring access, troubleshooting.

Makefile:
makefilesetup:       # aws configure check + terraform init
tf-plan:     # terraform plan
tf-apply:    # terraform apply -auto-approve
configure-k8s: # aws eks update-kubeconfig
deploy:      # kubectl apply -f k8s/
monitoring:  # helm install kube-prometheus-stack
teardown:    # terraform destroy


# Cost Management (Added)
AWS Budget Alert in Terraform (terraform/main.tf):

Budget: $30 threshold on the account
Email alert at 80% ($24) — warns before it gets expensive
Alert at 100% ($30) — hard stop signal

Reviewer IAM Access (read-only role in terraform/iam.tf):

IAM user mern-reviewer with console access
Attached policy: ReadOnlyAccess (AWS managed)
Scoped to EKS, ECR, CloudWatch, VPC resources
Output reviewer credentials via terraform output (shown in docs/deployment.md)
Instructions: share via a secure channel (1Password, encrypted email), delete after review

Teardown workflow:
`bashmake teardown       # kubectl delete ns mern-app monitoring
                    # helm uninstall monitoring
                    # terraform destroy -auto-approve  (~10 min)`