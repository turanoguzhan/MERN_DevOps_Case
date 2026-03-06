# Architecture Overview

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                         │
│                                                                   │
│  ┌──────────┐    Pull Request     ┌──────────────────────────┐  │
│  │Developer │ ─────────────────── │  GitHub Actions CI       │  │
│  │          │    Push to main     │  ─ Build Docker images   │  │
│  └──────────┘ ─────────────────── │  ─ Run Cypress E2E tests │  │
│                                   │  ─ Push to ECR           │  │
│                                   │  ─ Deploy to EKS         │  │
│                                   └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │ OIDC auth
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AWS (eu-central-1)                          │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    VPC (10.0.0.0/16)                     │    │
│  │                                                           │    │
│  │  Public Subnets (10.0.1-2.0/24)                         │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │  Internet Gateway    NAT Gateway    ALB          │    │    │
│  │  └─────────────────────────────────────────────────┘    │    │
│  │                      │                                   │    │
│  │  Private Subnets (10.0.3-4.0/24)                        │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │           EKS Cluster (K8s 1.29)                │    │    │
│  │  │                                                  │    │    │
│  │  │  Namespace: mern-app                            │    │    │
│  │  │  ┌──────────────┐   ┌──────────────────────┐   │    │    │
│  │  │  │ Frontend (x2)│   │   Backend (x2)        │   │    │    │
│  │  │  │ Nginx:80     │   │   Node.js:5050        │   │    │    │
│  │  │  │ React SPA    │   │   Express REST API     │   │    │    │
│  │  │  └──────────────┘   └──────────────────────┘   │    │    │
│  │  │                                                  │    │    │
│  │  │  Namespace: monitoring                          │    │    │
│  │  │  ┌──────────────┐   ┌────────────┐             │    │    │
│  │  │  │  Prometheus  │   │  Grafana   │             │    │    │
│  │  │  │  + Alertmgr  │   │  :3000     │             │    │    │
│  │  │  └──────────────┘   └────────────┘             │    │    │
│  │  └─────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌────────────┐   ┌─────────────────────────────────────────┐   │
│  │    ECR     │   │              MongoDB Atlas               │   │
│  │  frontend  │   │  (Managed, external — not in VPC)       │   │
│  │  backend   │   │  Connected via ATLAS_URI secret          │   │
│  └────────────┘   └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```


## Request Flow

```
User Browser
    │
    ▼
AWS ALB (internet-facing)
    │
    ├─── /api/* ──────► backend-service:5050 ──► MongoDB Atlas
    │                   (Express.js REST API)
    │
    └─── / ───────────► frontend-service:80
                        (Nginx serving React SPA)
                        │
                        └── /api/* (Nginx proxy) ──► backend-service:5050
```


## Component Breakdown

| Component | Technology | Port | Replicas |
|-----------|-----------|------|----------|
| Frontend | React 18 + Nginx | 80 | 2 |
| Backend | Node.js 20 + Express.js | 5050 | 2 |
| Database | MongoDB Atlas | 27017 | Managed |
| Ingress | AWS ALB | 80 | Managed |
| Monitoring | Prometheus + Grafana | 9090 / 3000 | 1 each |


## Infrastructure Components

| Component | Resource | Size |
|-----------|---------|------|
| VPC | 10.0.0.0/16 | 2 AZs |
| EKS Cluster | Kubernetes 1.29 | Managed |
| Worker Nodes | t3.medium | 2 (auto-scales 1–4) |
| Container Registry | Amazon ECR | 2 repos |
| Load Balancer | AWS ALB | Managed |


## CI/CD Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                      CI Pipeline (on PR)                         │
│                                                                   │
│  ┌──────────────┐  ┌────────────────────┐  ┌─────────────────┐  │
│  │ Server Tests │  │ Client Build +     │  │ Docker Build    │  │
│  │ - npm ci     │  │ Cypress E2E Tests  │  │ Verification    │  │
│  │ - syntax chk │  │ - npm run build    │  │ - client image  │  │
│  └──────────────┘  │ - cy:run headless  │  │ - server image  │  │
│                    └────────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    CD Pipeline (on merge to main)                │
│                                                                   │
│  OIDC Auth    Build & Push to ECR       Deploy to EKS            │
│  ──────────   ──────────────────────    ─────────────────────    │
│  No long-lived  - frontend image        - kubectl apply          │
│  credentials    - backend image         - rollout status wait    │
│  (secure)       - tagged with SHA       - smoke test ingress     │
└─────────────────────────────────────────────────────────────────┘
```


## Monitoring Stack

```
Prometheus ─── scrapes ──► backend:5050/metrics (prom-client)
           ─── scrapes ──► node-exporter (host metrics)
           ─── scrapes ──► kube-state-metrics (K8s state)
           │
           └── evaluates ──► Alert Rules
                              - PodCrashLooping (critical)
                              - HighHTTPErrorRate (critical)
                              - PodNotReady (warning)
                              - NodeHighCPU (warning)
                              - NodeHighMemory (warning)
                              │
                              └──► Alertmanager ──► notifications
                                                    (email / Slack)

Grafana ──► visualizes ──► Prometheus metrics
         ─── dashboards ──► Kubernetes Cluster Overview
                         ──► Node.js Application Metrics
```
