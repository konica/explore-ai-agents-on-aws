#!/usr/bin/env bash
set -euo pipefail

APP_NAME="hospital-scheduling-agent"
ECR_STACK="${APP_NAME}-ecr"
SERVICE_STACK="${APP_NAME}-service"
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

echo "=== Hospital Scheduling Agent - CloudFormation Cleanup ==="
echo "Region: ${REGION}"
echo ""

# Delete the service stack first: its task definition references the image
# in the ECR repo, so tear down the consumer before the repo.
echo "Deleting service stack (${SERVICE_STACK})..."
aws cloudformation delete-stack --stack-name "${SERVICE_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${SERVICE_STACK}" --region "${REGION}"
echo "  Deleted."

echo "Deleting ECR repository stack (${ECR_STACK})..."
aws cloudformation delete-stack --stack-name "${ECR_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${ECR_STACK}" --region "${REGION}"
echo "  Deleted (EmptyOnDelete removed all images first)."

echo ""
echo "=== Cleanup complete ==="
