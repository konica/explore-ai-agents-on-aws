#!/usr/bin/env bash
set -euo pipefail

APP_NAME="hospital-scheduling-agent-ec2"
SERVICE_STACK="${APP_NAME}-service"
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

echo "=== Hospital Scheduling Agent - CloudFormation Cleanup (EC2 launch type) ==="
echo "Region: ${REGION}"
echo ""

# Only deletes this stack -- the ECR repo (hospital-scheduling-agent-ecr) is
# shared with deploy-cfn.sh's Fargate variant, so it's left alone here. Run
# cleanup-cfn.sh separately once neither variant needs the shared repo.
echo "Deleting EC2 service stack (${SERVICE_STACK})..."
aws cloudformation delete-stack --stack-name "${SERVICE_STACK}" --region "${REGION}"
aws cloudformation wait stack-delete-complete --stack-name "${SERVICE_STACK}" --region "${REGION}"
echo "  Deleted (this also terminates the Auto Scaling Group's EC2 instances)."

echo ""
echo "=== Cleanup complete ==="
echo ""
echo "Note: the shared ECR repository stack (hospital-scheduling-agent-ecr) was"
echo "left in place. Run ./cleanup-cfn.sh to remove it once you're done with"
echo "both the Fargate and EC2 variants."
