#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
APP_NAME="hospital-scheduling-agent"
NAMESPACE="scheduling-agent"
SA_NAME="${APP_NAME}-sa"
CONTAINER_PORT=8080
MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
IMAGE_TAG="latest"

ECR_STACK="${APP_NAME}-ecr"
NETWORK_STACK="${APP_NAME}-eks-network"
CLUSTER_STACK="${APP_NAME}-eks-cluster"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cloudformation" && pwd)"

APP_ROLE_NAME="${APP_NAME}-irsa-role"
BEDROCK_POLICY_NAME="${APP_NAME}-bedrock-policy"
ALB_CONTROLLER_ROLE_NAME="${APP_NAME}-alb-controller-role"
ALB_CONTROLLER_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
ALB_CONTROLLER_SA_NAME="aws-load-balancer-controller"
# Pin to a specific aws-load-balancer-controller release so the IAM policy
# and the Helm chart's default image tag stay in sync. Check
# https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
# for newer versions.
ALB_CONTROLLER_VERSION="v2.13.0"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Hospital Scheduling Agent - EKS CloudFormation Deployment ==="
echo "Region:  ${REGION}"
echo "Account: ${ACCOUNT_ID}"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────
# No eksctl here: eks-network.yaml/eks-cluster.yaml (CloudFormation) own the
# VPC, cluster, Fargate profiles, and base IAM roles instead.
echo "Checking prerequisites..."
for cmd in aws docker kubectl helm envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." && exit 1
  fi
done
docker info &>/dev/null || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity &>/dev/null || { echo "ERROR: AWS credentials not configured."; exit 1; }
echo "All prerequisites met."
echo ""

# ── Step 1: Deploy the ECR repository stack ─────────────────────────
echo "Step 1/9: Deploying ECR repository stack (${ECR_STACK})..."
aws cloudformation deploy \
  --stack-name "${ECR_STACK}" \
  --template-file "${TEMPLATE_DIR}/ecr-repository.yaml" \
  --parameter-overrides "AppName=${APP_NAME}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

ECR_REPO=$(aws cloudformation describe-stacks --stack-name "${ECR_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text)
echo "  ECR repo: ${ECR_REPO}"

# ── Step 2: Build and push the Docker image ─────────────────────────
echo "Step 2/9: Building and pushing Docker image..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker build --platform linux/amd64 -t "${APP_NAME}:${IMAGE_TAG}" .
docker tag "${APP_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:${IMAGE_TAG}"
echo "  Image pushed: ${ECR_REPO}:${IMAGE_TAG}"

# ── Step 3: Deploy the network stack ─────────────────────────────────
# A default VPC's subnets are all public, but AWS::EKS::FargateProfile
# rejects public subnets outright, so this stack builds a dedicated
# VPC with a proper public/private split instead of reusing the default VPC.
echo "Step 3/9: Deploying network stack (${NETWORK_STACK})..."
aws cloudformation deploy \
  --stack-name "${NETWORK_STACK}" \
  --template-file "${TEMPLATE_DIR}/eks-network.yaml" \
  --parameter-overrides "AppName=${APP_NAME}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

VPC_ID=$(aws cloudformation describe-stacks --stack-name "${NETWORK_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
PUBLIC_SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name "${NETWORK_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetIds'].OutputValue" --output text)
PRIVATE_SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name "${NETWORK_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetIds'].OutputValue" --output text)
echo "  VPC: ${VPC_ID}"
echo "  Public subnets (ALB, NAT): ${PUBLIC_SUBNET_IDS}"
echo "  Private subnets (Fargate pods): ${PRIVATE_SUBNET_IDS}"

# ── Step 4: Deploy the EKS cluster stack ────────────────────────────
echo "Step 4/9: Deploying EKS cluster stack (${CLUSTER_STACK}) — first run takes 15-20 minutes..."
aws cloudformation deploy \
  --stack-name "${CLUSTER_STACK}" \
  --template-file "${TEMPLATE_DIR}/eks-cluster.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "AppName=${APP_NAME}" \
    "Namespace=${NAMESPACE}" \
    "PrivateSubnetIds=${PRIVATE_SUBNET_IDS}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)
OIDC_ISSUER_URL=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='OidcIssuerUrl'].OutputValue" --output text)
OIDC_PROVIDER_ARN=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='OidcProviderArn'].OutputValue" --output text)
OIDC_HOST="${OIDC_ISSUER_URL#https://}"
echo "  Cluster: ${CLUSTER_NAME}"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ── Step 5: Namespace ─────────────────────────────────────────────
echo "Step 5/9: Creating namespace..."
export NAMESPACE
envsubst < k8s/namespace.yaml | kubectl apply -f -

# ── Step 6: IRSA role for the app's service account ─────────────────
# CloudFormation stops at the OIDC provider (see cloudformation/EKS-CONCEPTS.md
# for why): an IRSA trust policy's Condition key must be the literal string
# "<oidc-issuer-host>:sub", and that can't be built from a stack output
# using CloudFormation's intrinsic functions. Resolve it here in bash instead.
echo "Step 6/9: Creating IAM role for the agent's Kubernetes service account..."

BEDROCK_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BEDROCK_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "${BEDROCK_POLICY_ARN}" &>/dev/null; then
  cat > /tmp/bedrock-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/*"
    ]
  }]
}
EOF
  aws iam create-policy \
    --policy-name "${BEDROCK_POLICY_NAME}" \
    --policy-document file:///tmp/bedrock-policy.json \
    --output text --query 'Policy.Arn'
  rm /tmp/bedrock-policy.json
fi

if ! aws iam get-role --role-name "${APP_ROLE_NAME}" &>/dev/null; then
  cat > /tmp/app-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}",
        "${OIDC_HOST}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
  aws iam create-role \
    --role-name "${APP_ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/app-trust-policy.json \
    --output text --query 'Role.Arn'
  rm /tmp/app-trust-policy.json
fi
aws iam attach-role-policy --role-name "${APP_ROLE_NAME}" --policy-arn "${BEDROCK_POLICY_ARN}"
APP_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${APP_ROLE_NAME}"

export APP_NAME SA_NAME
SA_ROLE_ARN="${APP_ROLE_ARN}" envsubst < k8s/serviceaccount.yaml | kubectl apply -f -
echo "  Service account: ${SA_NAME} (namespace ${NAMESPACE})"

# ── Step 7: Install the AWS Load Balancer Controller ────────────────
echo "Step 7/9: Installing the AWS Load Balancer Controller (provisions the ALB)..."

ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_CONTROLLER_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "${ALB_POLICY_ARN}" &>/dev/null; then
  curl -sL -o /tmp/alb-iam-policy.json \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${ALB_CONTROLLER_VERSION}/docs/install/iam_policy.json"
  aws iam create-policy \
    --policy-name "${ALB_CONTROLLER_POLICY_NAME}" \
    --policy-document file:///tmp/alb-iam-policy.json \
    --output text --query 'Policy.Arn'
  rm /tmp/alb-iam-policy.json
fi

if ! aws iam get-role --role-name "${ALB_CONTROLLER_ROLE_NAME}" &>/dev/null; then
  cat > /tmp/alb-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:sub": "system:serviceaccount:kube-system:${ALB_CONTROLLER_SA_NAME}",
        "${OIDC_HOST}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
  aws iam create-role \
    --role-name "${ALB_CONTROLLER_ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/alb-trust-policy.json \
    --output text --query 'Role.Arn'
  rm /tmp/alb-trust-policy.json
fi
aws iam attach-role-policy --role-name "${ALB_CONTROLLER_ROLE_NAME}" --policy-arn "${ALB_POLICY_ARN}"
ALB_CONTROLLER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ALB_CONTROLLER_ROLE_NAME}"

ALB_CONTROLLER_ROLE_ARN="${ALB_CONTROLLER_ROLE_ARN}" envsubst < k8s/serviceaccount-alb-controller.yaml | kubectl apply -f -

helm repo add eks https://aws.github.io/eks-charts &>/dev/null || true
helm repo update eks &>/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="${ALB_CONTROLLER_SA_NAME}"
echo "  AWS Load Balancer Controller installed."

# ── Step 8: Apply the Deployment, Service, and Ingress ──────────────
echo "Step 8/9: Applying Kubernetes manifests..."
export ECR_REPO IMAGE_TAG CONTAINER_PORT MODEL_ID
for f in k8s/deployment.yaml k8s/service.yaml k8s/ingress.yaml; do
  envsubst < "$f"
  echo "---"
done | kubectl apply -f -

# Force a fresh pull: the manifest's image reference never changes (always
# ":latest"), so a plain `apply` with no other diff won't restart pods.
kubectl rollout restart deployment/"${APP_NAME}" -n "${NAMESPACE}"
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=180s

# ── Step 9: Wait for the ALB to come up ─────────────────────────────
echo "Step 9/9: Waiting for the ALB (this can take a few minutes)..."
ALB_DNS=""
for _ in $(seq 1 30); do
  ALB_DNS=$(kubectl get ingress "${APP_NAME}-ingress" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "${ALB_DNS}" ] && break
  sleep 10
done

echo ""
echo "=== Deployment complete ==="
echo ""
if [ -n "${ALB_DNS}" ]; then
  echo "Once healthy, open in your browser:"
  echo "  http://${ALB_DNS}"
  echo ""
  echo "Or test with curl:"
  echo "  curl -X POST http://${ALB_DNS}/schedule -H 'Content-Type: application/json' -d '{\"message\": \"I need to schedule a knee arthroscopy for patient P-1234 with Dr. Smith next Tuesday\"}'"
else
  echo "ALB hostname not available yet. Check status with:"
  echo "  kubectl get ingress ${APP_NAME}-ingress -n ${NAMESPACE}"
fi
echo ""
echo "View logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app=${APP_NAME} --follow"
echo ""
echo "Tear down everything:"
echo "  ./cleanup-cfn.sh"
