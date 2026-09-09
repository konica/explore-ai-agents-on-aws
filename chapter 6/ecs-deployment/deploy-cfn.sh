#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
APP_NAME="hospital-scheduling-agent"
CONTAINER_PORT=8080
CPU=1024        # 1 vCPU
MEMORY=2048     # 2 GB
DESIRED_COUNT=1
MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
# Unique per run (not "latest"): the TaskDefinition's Image property must
# actually change for CloudFormation to detect a diff and update the ECS
# service. A fixed tag makes every redeploy an empty changeset -- the new
# image gets pushed to ECR but the running task is never replaced.
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"

ECR_STACK="${APP_NAME}-ecr"
SERVICE_STACK="${APP_NAME}-service"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cloudformation" && pwd)"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Hospital Scheduling Agent - CloudFormation Deployment ==="
echo "Region:  ${REGION}"
echo "Account: ${ACCOUNT_ID}"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────
echo "Checking prerequisites..."
for cmd in aws docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." && exit 1
  fi
done
docker info &>/dev/null || { echo "ERROR: Docker is not running."; exit 1; }
aws sts get-caller-identity &>/dev/null || { echo "ERROR: AWS credentials not configured."; exit 1; }
echo "All prerequisites met."
echo ""

# ── Step 1: Deploy the ECR repository stack ────────────────────────
echo "Step 1/4: Deploying ECR repository stack (${ECR_STACK})..."
aws cloudformation deploy \
  --stack-name "${ECR_STACK}" \
  --template-file "${TEMPLATE_DIR}/ecr-repository.yaml" \
  --parameter-overrides "AppName=${APP_NAME}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

ECR_REPO=$(aws cloudformation describe-stacks --stack-name "${ECR_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text)
echo "  ECR repo: ${ECR_REPO}"
echo ""

# ── Step 2: Build and push the Docker image ─────────────────────────
echo "Step 2/4: Building and pushing Docker image..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker build --platform linux/amd64 -t "${APP_NAME}:${IMAGE_TAG}" .
docker tag "${APP_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:${IMAGE_TAG}"
echo "  Image pushed: ${ECR_REPO}:${IMAGE_TAG}"
echo ""

# ── Step 3: Discover a VPC and its public subnets ───────────────────
echo "Step 3/4: Discovering VPC and public subnets..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)

IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters Name=attachment.vpc-id,Values="${VPC_ID}" \
  --region "${REGION}" --query 'InternetGateways[0].InternetGatewayId' --output text)

# Find subnets whose route table sends 0.0.0.0/0 through the IGW.
# An internet-facing ALB requires this; subnets routed through a NAT gateway won't work.
PUBLIC_SUBNETS=()
ALL_SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" Name=default-for-az,Values=true \
  --region "${REGION}" --query 'Subnets[*].SubnetId' --output text)
for SID in ${ALL_SUBNETS}; do
  RT_ID=$(aws ec2 describe-route-tables \
    --filters Name=association.subnet-id,Values="${SID}" \
    --region "${REGION}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if [ -z "${RT_ID}" ] || [ "${RT_ID}" = "None" ]; then
    RT_ID=$(aws ec2 describe-route-tables \
      --filters Name=vpc-id,Values="${VPC_ID}" Name=association.main,Values=true \
      --region "${REGION}" --query 'RouteTables[0].RouteTableId' --output text)
  fi
  GW=$(aws ec2 describe-route-tables --route-table-ids "${RT_ID}" \
    --region "${REGION}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" --output text)
  if [ "${GW}" = "${IGW_ID}" ]; then
    PUBLIC_SUBNETS+=("${SID}")
  fi
done

if [ "${#PUBLIC_SUBNETS[@]}" -lt 2 ]; then
  echo "ERROR: Need at least 2 public subnets (routed through IGW) for the ALB."
  echo "       Found ${#PUBLIC_SUBNETS[@]}. Check your VPC route tables."
  exit 1
fi
SUBNET_1="${PUBLIC_SUBNETS[0]}"
SUBNET_2="${PUBLIC_SUBNETS[1]}"
echo "  VPC: ${VPC_ID}"
echo "  Public subnets: ${SUBNET_1}, ${SUBNET_2}"
echo ""

# ── Step 4: Deploy the ECS service stack ────────────────────────────
echo "Step 4/4: Deploying ECS service stack (${SERVICE_STACK})..."
aws cloudformation deploy \
  --stack-name "${SERVICE_STACK}" \
  --template-file "${TEMPLATE_DIR}/ecs-service.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "AppName=${APP_NAME}" \
    "EcrRepositoryUri=${ECR_REPO}" \
    "ImageTag=${IMAGE_TAG}" \
    "ModelId=${MODEL_ID}" \
    "VpcId=${VPC_ID}" \
    "PublicSubnetIds=${SUBNET_1},${SUBNET_2}" \
    "ContainerPort=${CONTAINER_PORT}" \
    "ContainerCpu=${CPU}" \
    "ContainerMemory=${MEMORY}" \
    "DesiredCount=${DESIRED_COUNT}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

ALB_DNS=$(aws cloudformation describe-stacks --stack-name "${SERVICE_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text)
LOG_GROUP=$(aws cloudformation describe-stacks --stack-name "${SERVICE_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='LogGroupName'].OutputValue" --output text)

echo ""
echo "=== Deployment complete ==="
echo ""
echo "The ECS service is stabilizing (aws cloudformation deploy already waited"
echo "for CREATE_COMPLETE/UPDATE_COMPLETE, but health checks can take another"
echo "minute or two)."
echo ""
echo "Once healthy, open in your browser:"
echo "  http://${ALB_DNS}"
echo ""
echo "Or test with curl:"
echo "  curl -X POST http://${ALB_DNS}/schedule -H 'Content-Type: application/json' -d '{\"message\": \"I need to schedule a knee arthroscopy for patient P-1234 with Dr. Smith next Tuesday\"}'"
echo ""
echo "View logs:"
echo "  aws logs tail ${LOG_GROUP} --follow --region ${REGION}"
echo ""
echo "Tear down both stacks:"
echo "  ./cleanup-cfn.sh"
