#!/usr/bin/env bash
set -euo pipefail

# ── Configuration (must match deploy.sh) ───────────────────────────
APP_NAME="hospital-scheduling-agent"
CLUSTER_NAME="agent-eks-cluster"
NAMESPACE="scheduling-agent"
SA_NAME="${APP_NAME}-sa"
FARGATE_PROFILE="${APP_NAME}-fp"
BEDROCK_POLICY_NAME="${APP_NAME}-bedrock-policy"
ALB_CONTROLLER_NAMESPACE="kube-system"
ALB_CONTROLLER_SA_NAME="aws-load-balancer-controller"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Cleaning up Hospital Scheduling Agent (EKS) ==="
echo ""

# ── Delete the Ingress/Service/Deployment ──────────────────────────
# Must happen before the cluster goes away: the AWS Load Balancer Controller
# only deletes the ALB and target group it created when it sees the Ingress
# object deleted. Delete the cluster first and the ALB is orphaned.
echo "Deleting Kubernetes resources..."
kubectl delete ingress "${APP_NAME}-ingress" -n "${NAMESPACE}" --ignore-not-found
kubectl delete service "${APP_NAME}-svc" -n "${NAMESPACE}" --ignore-not-found
kubectl delete deployment "${APP_NAME}" -n "${NAMESPACE}" --ignore-not-found

echo "  Waiting for the ALB Controller to release the load balancer..."
sleep 30

# ── Uninstall the AWS Load Balancer Controller ─────────────────────
echo "Uninstalling the AWS Load Balancer Controller..."
helm uninstall aws-load-balancer-controller -n "${ALB_CONTROLLER_NAMESPACE}" 2>/dev/null || true

# ── Delete IRSA service accounts (each is backed by a CloudFormation
#    stack that eksctl created; deleting the cluster does NOT clean
#    these up on its own) ──────────────────────────────────────────
echo "Deleting IAM service accounts..."
eksctl delete iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" \
  --namespace "${NAMESPACE}" --name "${SA_NAME}" 2>/dev/null || true
eksctl delete iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" \
  --namespace "${ALB_CONTROLLER_NAMESPACE}" --name "${ALB_CONTROLLER_SA_NAME}" 2>/dev/null || true

# ── Delete the app's Bedrock IAM policy ────────────────────────────
# The AWSLoadBalancerControllerIAMPolicy is intentionally left in place:
# it's a shared, cluster-agnostic policy other EKS clusters in this
# account may also depend on.
echo "Deleting the Bedrock access policy..."
BEDROCK_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BEDROCK_POLICY_NAME}"
aws iam delete-policy --policy-arn "${BEDROCK_POLICY_ARN}" 2>/dev/null || true

# ── Delete the Fargate profile ──────────────────────────────────────
echo "Deleting the Fargate profile..."
eksctl delete fargateprofile \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" \
  --name "${FARGATE_PROFILE}" --wait 2>/dev/null || true

# ── Delete the EKS cluster ──────────────────────────────────────────
echo "Deleting the EKS cluster (this takes several minutes)..."
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null || true

# ── Delete the ECR repository ──────────────────────────────────────
echo "Deleting ECR repository..."
aws ecr delete-repository --repository-name "${APP_NAME}" --force --region "${REGION}" --output text 2>/dev/null || true

echo ""
echo "=== Cleanup complete ==="
echo "All resources for ${APP_NAME} have been removed."
