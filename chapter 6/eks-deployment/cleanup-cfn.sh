#!/usr/bin/env bash
set -euo pipefail

# ── Configuration (must match deploy-cfn.sh) ───────────────────────
APP_NAME="hospital-scheduling-agent"
NAMESPACE="scheduling-agent"
ECR_STACK="${APP_NAME}-ecr"
NETWORK_STACK="${APP_NAME}-eks-network"
CLUSTER_STACK="${APP_NAME}-eks-cluster"

APP_ROLE_NAME="${APP_NAME}-irsa-role"
BEDROCK_POLICY_NAME="${APP_NAME}-bedrock-policy"
ALB_CONTROLLER_ROLE_NAME="${APP_NAME}-alb-controller-role"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Hospital Scheduling Agent - EKS CloudFormation Cleanup ==="
echo "Region: ${REGION}"
echo ""

# ── Delete the Ingress/Service/Deployment ──────────────────────────
# Must happen before the cluster stack is deleted: the AWS Load Balancer
# Controller only deletes the ALB and target group it created when it sees
# the Ingress object deleted. Delete the cluster first and the ALB is
# orphaned.
echo "Deleting Kubernetes resources..."
if aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" --region "${REGION}" &>/dev/null; then
  CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" \
    --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text 2>/dev/null || true)
  if [ -n "${CLUSTER_NAME}" ] && [ "${CLUSTER_NAME}" != "None" ]; then
    aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null || true
    kubectl delete ingress "${APP_NAME}-ingress" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete service "${APP_NAME}-svc" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete deployment "${APP_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

    echo "  Waiting for the ALB Controller to release the load balancer..."
    sleep 30

    echo "  Uninstalling the AWS Load Balancer Controller..."
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
  fi
fi

# ── Delete the app and ALB Controller IAM roles ─────────────────────
echo "Deleting IAM roles..."
BEDROCK_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BEDROCK_POLICY_NAME}"
ALB_CONTROLLER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

aws iam detach-role-policy --role-name "${APP_ROLE_NAME}" --policy-arn "${BEDROCK_POLICY_ARN}" 2>/dev/null || true
aws iam delete-role --role-name "${APP_ROLE_NAME}" 2>/dev/null || true

aws iam detach-role-policy --role-name "${ALB_CONTROLLER_ROLE_NAME}" --policy-arn "${ALB_CONTROLLER_POLICY_ARN}" 2>/dev/null || true
aws iam delete-role --role-name "${ALB_CONTROLLER_ROLE_NAME}" 2>/dev/null || true

# The app's Bedrock policy is app-specific — safe to delete. The
# AWSLoadBalancerControllerIAMPolicy managed policy is intentionally left in
# place: other clusters in this account may also depend on it.
aws iam delete-policy --policy-arn "${BEDROCK_POLICY_ARN}" 2>/dev/null || true

# ── Delete the EKS cluster stack ─────────────────────────────────────
# Removes the Cluster, both Fargate profiles, ClusterRole,
# FargatePodExecutionRole, and the OIDC provider.
echo "Deleting EKS cluster stack (${CLUSTER_STACK}) — this takes several minutes..."
aws cloudformation delete-stack --stack-name "${CLUSTER_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER_STACK}" --region "${REGION}"
echo "  Deleted."

# ── Delete the network stack ─────────────────────────────────────────
# Must happen after the cluster stack: the cluster's ENIs and the Fargate
# profiles' pods still occupy the private subnets while it exists.
echo "Deleting network stack (${NETWORK_STACK})..."
aws cloudformation delete-stack --stack-name "${NETWORK_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${NETWORK_STACK}" --region "${REGION}"
echo "  Deleted."

# ── Delete the ECR repository stack ─────────────────────────────────
# Shared with ecs-deployment's deploy-cfn.sh (same AppName/repo name) — only
# run this if nothing else is still using that image.
echo "Deleting ECR repository stack (${ECR_STACK})..."
aws cloudformation delete-stack --stack-name "${ECR_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${ECR_STACK}" --region "${REGION}"
echo "  Deleted (EmptyOnDelete removed all images first)."

echo ""
echo "=== Cleanup complete ==="
