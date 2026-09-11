#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
APP_NAME="hospital-scheduling-agent"
CLUSTER_NAME="agent-eks-cluster"
NAMESPACE="scheduling-agent"
SA_NAME="${APP_NAME}-sa"
FARGATE_PROFILE="${APP_NAME}-fp"
CONTAINER_PORT=8080
MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"

BEDROCK_POLICY_NAME="${APP_NAME}-bedrock-policy"
ALB_CONTROLLER_NAMESPACE="kube-system"
ALB_CONTROLLER_SA_NAME="aws-load-balancer-controller"
ALB_CONTROLLER_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
# Pin to a specific aws-load-balancer-controller release so the IAM policy
# and the Helm chart's default image tag stay in sync. Check
# https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
# for newer versions.
ALB_CONTROLLER_VERSION="v2.13.0"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}"
IMAGE_TAG="latest"

echo "=== Hospital Scheduling Agent - EKS (Fargate) Deployment ==="
echo "Region:  ${REGION}"
echo "Account: ${ACCOUNT_ID}"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────
echo "Checking prerequisites..."
for cmd in aws docker eksctl kubectl helm envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." && exit 1
  fi
done
docker info &>/dev/null || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity &>/dev/null || { echo "ERROR: AWS credentials not configured."; exit 1; }
echo "All prerequisites met."
echo ""

# ── Step 1: Create ECR repository ─────────────────────────────────
echo "Step 1/8: Creating ECR repository..."
aws ecr describe-repositories --repository-names "${APP_NAME}" --region "${REGION}" &>/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "${APP_NAME}" --region "${REGION}" --output text --query 'repository.repositoryUri'
echo "  ECR repo: ${ECR_REPO}"

# ── Step 2: Build and push Docker image ────────────────────────────
echo "Step 2/8: Building and pushing Docker image..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker build --platform linux/amd64 -t "${APP_NAME}:${IMAGE_TAG}" .
docker tag "${APP_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:${IMAGE_TAG}"
echo "  Image pushed: ${ECR_REPO}:${IMAGE_TAG}"

# ── Step 3: Create the EKS cluster (Fargate-only control plane) ────
echo "Step 3/8: Creating EKS cluster (this takes 15-20 minutes on a first run)..."
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
  echo "  Cluster already exists: ${CLUSTER_NAME}"
else
  eksctl create cluster \
    --name "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --fargate
fi

# eksctl create cluster --fargate associates the IAM OIDC provider already,
# but this keeps the script idempotent if the cluster was created some
# other way (e.g. the console) or by an older eksctl version.
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" --approve
echo "  Cluster: ${CLUSTER_NAME}"

# ── Step 4: Namespace + Fargate profile for the app ────────────────
echo "Step 4/8: Creating namespace and Fargate profile..."
kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"

if eksctl get fargateprofile --cluster "${CLUSTER_NAME}" --region "${REGION}" \
     -o json | grep -q "\"${FARGATE_PROFILE}\""; then
  echo "  Fargate profile already exists: ${FARGATE_PROFILE}"
else
  eksctl create fargateprofile \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --name "${FARGATE_PROFILE}" \
    --namespace "${NAMESPACE}"
fi
echo "  Namespace: ${NAMESPACE}, Fargate profile: ${FARGATE_PROFILE}"

# ── Step 5: Install the AWS Load Balancer Controller ───────────────
echo "Step 5/8: Installing the AWS Load Balancer Controller (provisions the ALB)..."

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

eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" \
  --namespace "${ALB_CONTROLLER_NAMESPACE}" \
  --name "${ALB_CONTROLLER_SA_NAME}" \
  --attach-policy-arn "${ALB_POLICY_ARN}" \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts &>/dev/null || true
helm repo update eks &>/dev/null

VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# --wait matters: without it, `helm upgrade --install` returns as soon as the
# release is recorded, not once the controller's pod is actually Ready. The
# Ingress applied in Step 7 is intercepted by the controller's admission
# webhook — on Fargate, pod scheduling is slow enough that the webhook has no
# endpoints yet, and kubectl apply fails with "no endpoints available for
# service aws-load-balancer-webhook-service".
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n "${ALB_CONTROLLER_NAMESPACE}" \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="${ALB_CONTROLLER_SA_NAME}" \
  --wait --timeout 5m
echo "  AWS Load Balancer Controller installed and ready."

# ── Step 6: IRSA service account for Bedrock access ────────────────
echo "Step 6/8: Creating IAM role for the agent's Kubernetes service account..."

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

eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --region "${REGION}" \
  --namespace "${NAMESPACE}" \
  --name "${SA_NAME}" \
  --attach-policy-arn "${BEDROCK_POLICY_ARN}" \
  --override-existing-serviceaccounts \
  --approve
echo "  Service account: ${SA_NAME} (namespace ${NAMESPACE})"

# ── Step 7: Apply the Deployment, Service, and Ingress ─────────────
echo "Step 7/8: Applying Kubernetes manifests..."
export APP_NAME NAMESPACE SA_NAME ECR_REPO IMAGE_TAG CONTAINER_PORT MODEL_ID
for f in k8s/deployment.yaml k8s/service.yaml k8s/ingress.yaml; do
  envsubst < "$f"
  echo "---"
done | kubectl apply -f -

# Force a fresh pull: the manifest's image reference never changes (always
# ":latest"), so a plain `apply` with no other diff won't restart pods.
kubectl rollout restart deployment/"${APP_NAME}" -n "${NAMESPACE}"
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=180s

# ── Step 8: Wait for the ALB to come up ────────────────────────────
echo "Step 8/8: Waiting for the ALB (this can take a few minutes)..."
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
