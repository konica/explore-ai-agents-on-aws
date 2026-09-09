#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Shares the ECR repo/image with deploy-cfn.sh (same underlying app image
# works on either launch type); only the service stack name/resources differ.
BASE_APP_NAME="hospital-scheduling-agent"
APP_NAME="hospital-scheduling-agent-ec2"
CONTAINER_PORT=8080
CPU=1024        # task-level reservation, not a Fargate CPU/memory pairing
MEMORY=2048     # MiB
DESIRED_COUNT=1
INSTANCE_TYPE="t3.medium"
DESIRED_CAPACITY=1
MIN_SIZE=1
MAX_SIZE=2
MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
# Unique per run (not "latest"): see deploy-cfn.sh -- CloudFormation only
# updates the service when the TaskDefinition's Image property actually changes.
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"

ECR_STACK="${BASE_APP_NAME}-ecr"
SERVICE_STACK="${APP_NAME}-service"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cloudformation" && pwd)"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Hospital Scheduling Agent - CloudFormation Deployment (EC2 launch type) ==="
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

# ── Step 1: Deploy (or reuse) the shared ECR repository stack ──────
echo "Step 1/4: Deploying ECR repository stack (${ECR_STACK})..."
aws cloudformation deploy \
  --stack-name "${ECR_STACK}" \
  --template-file "${TEMPLATE_DIR}/ecr-repository.yaml" \
  --parameter-overrides "AppName=${BASE_APP_NAME}" \
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

docker build --platform linux/amd64 -t "${BASE_APP_NAME}:${IMAGE_TAG}" .
docker tag "${BASE_APP_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
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
# The ALB requires this, and so do the container instances (no NAT gateway here).
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

# ── Step 4: Deploy the EC2-launch-type ECS service stack ────────────
echo "Step 4/4: Deploying ECS service stack (${SERVICE_STACK})..."
aws cloudformation deploy \
  --stack-name "${SERVICE_STACK}" \
  --template-file "${TEMPLATE_DIR}/ecs-service-ec2.yaml" \
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
    "InstanceType=${INSTANCE_TYPE}" \
    "DesiredCapacity=${DESIRED_CAPACITY}" \
    "MinSize=${MIN_SIZE}" \
    "MaxSize=${MAX_SIZE}" \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

ALB_DNS=$(aws cloudformation describe-stacks --stack-name "${SERVICE_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text)
LOG_GROUP=$(aws cloudformation describe-stacks --stack-name "${SERVICE_STACK}" \
  --region "${REGION}" --query "Stacks[0].Outputs[?OutputKey=='LogGroupName'].OutputValue" --output text)

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Unlike Fargate, this needs an EC2 instance to actually boot and join the"
echo "cluster before any task can place -- the service may take several extra"
echo "minutes to stabilize on first deploy (or after MinSize/MaxSize changes)."
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
echo "Tear down this stack (leaves the shared ECR repo alone):"
echo "  ./cleanup-cfn-ec2.sh"
