.PHONY: help setup tf-init tf-plan tf-apply tf-destroy configure-kubectl deploy-k8s monitoring teardown clean

# Default target
help:
	@echo ""
	@echo "MERN DevOps Case — Available Make Targets"
	@echo "==========================================="
	@echo ""
	@echo "  setup             Check prerequisites (AWS CLI, kubectl, helm, terraform)"
	@echo "  tf-init           Initialize Terraform (downloads providers)"
	@echo "  tf-plan           Preview Terraform changes"
	@echo "  tf-apply          Provision AWS infrastructure (VPC, EKS, ECR)"
	@echo "  configure-kubectl Configure kubectl for the EKS cluster"
	@echo "  deploy-k8s        Deploy application to Kubernetes"
	@echo "  monitoring        Install Prometheus + Grafana via Helm"
	@echo "  teardown          Delete all K8s resources and destroy Terraform infra"
	@echo "  clean             Remove local build artifacts"
	@echo ""

# ────────────────────────────────────────────────
# Prerequisites check
# ────────────────────────────────────────────────
setup:
	@echo "Checking prerequisites..."
	@command -v aws      >/dev/null 2>&1 || (echo "ERROR: aws CLI not found. Install: https://aws.amazon.com/cli/" && exit 1)
	@command -v kubectl  >/dev/null 2>&1 || (echo "ERROR: kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/" && exit 1)
	@command -v helm     >/dev/null 2>&1 || (echo "ERROR: helm not found. Install: https://helm.sh/docs/intro/install/" && exit 1)
	@command -v terraform>/dev/null 2>&1 || (echo "ERROR: terraform not found. Install: https://developer.hashicorp.com/terraform/downloads" && exit 1)
	@command -v docker   >/dev/null 2>&1 || (echo "ERROR: docker not found. Install: https://docs.docker.com/get-docker/" && exit 1)
	@echo "All prerequisites found."
	@echo ""
	@echo "Verifying AWS credentials..."
	@aws sts get-caller-identity
	@echo "AWS credentials OK."

# ────────────────────────────────────────────────
# Terraform — Infrastructure
# ────────────────────────────────────────────────

# Download the AWS Load Balancer Controller IAM policy (required by EKS module)
download-lbc-policy:
	@echo "Downloading AWS Load Balancer Controller IAM policy..."
	curl -o terraform/modules/eks/lbc-iam-policy.json \
		https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.2/docs/install/iam_policy.json
	@echo "Policy downloaded."

tf-init: download-lbc-policy
	@echo "Initializing Terraform..."
	cd terraform && terraform init

tf-plan:
	@echo "Planning Terraform changes..."
	cd terraform && terraform plan -var-file=terraform.tfvars

tf-apply:
	@echo "Applying Terraform — this will provision AWS resources (~15 min)..."
	cd terraform && terraform apply -var-file=terraform.tfvars -auto-approve
	@echo ""
	@echo "Infrastructure ready. Key outputs:"
	cd terraform && terraform output

# ────────────────────────────────────────────────
# Kubernetes — Cluster Configuration
# ────────────────────────────────────────────────

configure-kubectl:
	@echo "Configuring kubectl for EKS cluster..."
	$(eval CLUSTER_NAME := $(shell cd terraform && terraform output -raw eks_cluster_name))
	$(eval AWS_REGION := $(shell cd terraform && terraform output -raw aws_region 2>/dev/null || echo "eu-central-1"))
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)
	@echo "kubectl configured. Cluster info:"
	kubectl cluster-info

# ────────────────────────────────────────────────
# AWS Load Balancer Controller — Install
# ────────────────────────────────────────────────

install-alb-controller:
	@echo "Installing AWS Load Balancer Controller..."
	$(eval LBC_ROLE_ARN := $(shell cd terraform && terraform output -raw aws_lbc_role_arn 2>/dev/null))
	$(eval CLUSTER_NAME := $(shell cd terraform && terraform output -raw eks_cluster_name))
	helm repo add eks https://aws.github.io/eks-charts
	helm repo update
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		-n kube-system \
		--set clusterName=$(CLUSTER_NAME) \
		--set serviceAccount.create=true \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(LBC_ROLE_ARN)
	@echo "AWS Load Balancer Controller installed."

# ────────────────────────────────────────────────
# Application Deployment
# ────────────────────────────────────────────────

deploy-k8s:
	@echo "Deploying MERN application to Kubernetes..."
	@[ -n "$(ECR_FRONTEND)" ] || (echo "ERROR: ECR_FRONTEND env var not set" && exit 1)
	@[ -n "$(ECR_BACKEND)"  ] || (echo "ERROR: ECR_BACKEND env var not set"  && exit 1)
	@[ -n "$(IMAGE_TAG)"    ] || (echo "ERROR: IMAGE_TAG env var not set"     && exit 1)
	@[ -n "$(ATLAS_URI)"    ] || (echo "ERROR: ATLAS_URI env var not set"     && exit 1)
	kubectl apply -f k8s/namespace.yaml
	kubectl create secret generic mern-secret \
		--namespace mern-app \
		--from-literal=ATLAS_URI="$(ATLAS_URI)" \
		--dry-run=client -o yaml | kubectl apply -f -
	IMAGE_TAG=$(IMAGE_TAG) ECR_BACKEND=$(ECR_BACKEND) envsubst < k8s/backend/deployment.yaml | kubectl apply -f -
	kubectl apply -f k8s/backend/service.yaml
	IMAGE_TAG=$(IMAGE_TAG) ECR_FRONTEND=$(ECR_FRONTEND) envsubst < k8s/frontend/deployment.yaml | kubectl apply -f -
	kubectl apply -f k8s/frontend/service.yaml
	kubectl apply -f k8s/ingress.yaml
	@echo "Waiting for rollout..."
	kubectl rollout status deployment/backend -n mern-app --timeout=300s
	kubectl rollout status deployment/frontend -n mern-app --timeout=300s
	@echo ""
	@echo "Application deployed. Ingress:"
	kubectl get ingress mern-ingress -n mern-app

# ────────────────────────────────────────────────
# Monitoring
# ────────────────────────────────────────────────

monitoring:
	@echo "Installing Prometheus + Grafana (kube-prometheus-stack)..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--create-namespace \
		--values monitoring/prometheus-values.yaml \
		--timeout 10m
	kubectl apply -f monitoring/alert-rules.yaml
	@echo ""
	@echo "Monitoring installed. Grafana URL:"
	kubectl get svc -n monitoring monitoring-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
	@echo ""
	@echo "Default credentials: admin / (set via grafana.adminPassword in prometheus-values.yaml)"

# ────────────────────────────────────────────────
# Teardown
# ────────────────────────────────────────────────

teardown:
	@echo "WARNING: This will delete ALL resources and destroy AWS infrastructure."
	@read -p "Are you sure? Type 'yes' to continue: " CONFIRM && [ "$$CONFIRM" = "yes" ] || exit 1
	@echo "Removing Kubernetes resources..."
	-kubectl delete namespace mern-app --ignore-not-found
	-helm uninstall monitoring -n monitoring 2>/dev/null || true
	-kubectl delete namespace monitoring --ignore-not-found
	-helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
	@echo "Destroying Terraform infrastructure (~10 min)..."
	cd terraform && terraform destroy -var-file=terraform.tfvars -auto-approve
	@echo "Teardown complete."

clean:
	@echo "Cleaning local build artifacts..."
	rm -rf mern-project/client/build
	rm -rf mern-project/client/node_modules
	rm -rf mern-project/server/node_modules
	@echo "Done."
