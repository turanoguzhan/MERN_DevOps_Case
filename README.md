![result](result.png "Result")

# MERN DevOps Case

A full-stack MERN application deployed to AWS EKS with production-grade DevOps infrastructure.

## Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18 + Nginx |
| Backend | Node.js 20 + Express.js |
| Database | MongoDB Atlas (managed) |
| Container Registry | Amazon ECR |
| Orchestration | Amazon EKS (Kubernetes 1.29) |
| Infrastructure | Terraform (VPC + EKS + ECR + IAM) |
| CI/CD | GitHub Actions (OIDC auth) |
| Monitoring | Prometheus + Grafana + Alertmanager |

## Quick Start

### Local Development (Docker Compose)

```bash
# Copy and fill in your MongoDB Atlas URI
cp mern-project/server/.env.example mern-project/server/.env

# Start both services
cd mern-project && docker-compose up --build

# App available at http://localhost:3000
# API available at http://localhost:5050
```

### AWS Deployment

```bash
# 1. Check prerequisites
make setup

# 2. Provision infrastructure
make tf-init
make tf-apply

# 3. Configure kubectl
make configure-kubectl

# 4. Install AWS Load Balancer Controller
make install-alb-controller

# 5. Configure GitHub Secrets (see docs/deployment.md)
# Then push to main to trigger CI/CD

# 6. Install monitoring
make monitoring
```

See **[docs/deployment.md](docs/deployment.md)** for the full step-by-step guide.

See **[docs/architecture.md](docs/architecture.md)** for architecture diagrams.

## Project Structure

```
├── mern-project/
│   ├── client/           # React 18 frontend
│   │   ├── Dockerfile    # Multi-stage: Node build → Nginx serve
│   │   └── nginx.conf    # SPA routing + /api proxy
│   ├── server/           # Express.js REST API
│   │   └── Dockerfile    # Node 20 alpine
│   └── docker-compose.yml
├── k8s/                  # Kubernetes manifests
│   ├── namespace.yaml
│   ├── backend/          # Deployment + Service
│   ├── frontend/         # Deployment + Service
│   └── ingress.yaml      # AWS ALB Ingress
├── terraform/            # Infrastructure as Code
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, IGW, NAT
│   │   ├── eks/          # EKS cluster + node group
│   │   └── ecr/          # ECR repositories
│   └── iam.tf            # GitHub Actions OIDC + reviewer role
├── monitoring/
│   ├── prometheus-values.yaml   # Helm values
│   └── alert-rules.yaml         # Custom alert rules
├── .github/workflows/
│   ├── ci.yml            # PR: build, test, Dockerfile check
│   └── cd.yml            # main push: build→ECR→EKS deploy
├── docs/
│   ├── architecture.md   # Architecture diagrams
│   └── deployment.md     # Step-by-step deployment guide
├── Makefile              # Convenience commands
└── python-project/
    └── ETL.py            # Hourly ETL script (cron job)
```

## Acceptance Criteria

### MERN Project
1. MongoDB Atlas connected via `ATLAS_URI` secret
2. All endpoints work: `GET/POST/PATCH/DELETE /record/`, `GET /healthcheck/`
3. All pages work: Record List, Create, Edit, Health Status
4. Prometheus metrics available at `GET /metrics`

### Python Project
1. `ETL.py` runs every 1 hour via Kubernetes CronJob

## CI/CD Pipeline

- **CI** (pull requests): lint, build, Cypress E2E tests, Docker build verification
- **CD** (merge to main): build images → push to ECR → deploy to EKS via OIDC (keyless)

## Monitoring & Alerts

Grafana dashboards: Kubernetes cluster overview + Node.js application metrics

Alert rules:
- `PodCrashLooping` — critical
- `HighHTTPErrorRate` — critical
- `BackendDown` — critical
- `PodNotReady` — warning
- `NodeHighCPUUsage` — warning
- `NodeHighMemoryUsage` — warning
