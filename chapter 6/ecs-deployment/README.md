# ECS Fargate Deployment: Hospital Scheduling Agent

A Strands agent deployed on ECS Fargate behind an Application Load Balancer.
The agent coordinates surgical scheduling by checking provider availability,
equipment needs, and operating room schedules.

This follows the architecture from the
[official Strands Fargate deployment guide](https://strandsagents.com/docs/user-guide/deploy/deploy_to_aws_fargate/).

## Architecture

```
Browser (chat UI) → ALB (port 80) → ECS Fargate Task → Bedrock (Claude)
                                         ↓
                                   FastAPI + Strands Agent
                                   (tools: provider calendar,
                                    equipment check, booking)
```

## Prerequisites

- AWS account with credentials configured (`aws sts get-caller-identity`)
- Docker installed and running (`docker info`)
- Amazon Bedrock model access enabled for Claude Sonnet (Anthropic) in us-east-1
- AWS CLI v2 (`aws --version`)

## Deploy

```bash
chmod +x deploy.sh cleanup.sh
./deploy.sh
```

The script creates everything: ECR repo, Docker image, IAM roles, ECS cluster,
task definition, ALB, security groups, and the Fargate service. Takes about
3-4 minutes.

On Windows, run from WSL or Git Bash.

## Test

Wait 2-3 minutes after deploy for the task to start and pass health checks,
then open the ALB URL in your browser:

```
http://<ALB_DNS>
```

You'll see a chat interface where you can type scheduling requests or click
one of the suggestion buttons. The deploy script prints the ALB DNS name at
the end.

You can also test with curl:

```bash
# Health check
curl http://<ALB_DNS>/health

# Schedule a procedure
curl -X POST http://<ALB_DNS>/schedule \
  -H 'Content-Type: application/json' \
  -d '{"message": "Schedule a knee arthroscopy for patient P-1234 with Dr. Smith on 2026-03-18"}'
```

## View Logs

```bash
aws logs tail /ecs/scheduling-agent --follow --region us-east-1
```

## Clean Up

```bash
./cleanup.sh
```

Removes all AWS resources: ECS service, cluster, ALB, target group, security
groups, ECR repo, IAM roles, and CloudWatch log group.

## Cost

Fargate pricing is per-second for the vCPU and memory your task uses. With the
default config (1 vCPU, 2 GB, 1 task), expect roughly $0.05/hour while running.
The ALB adds a small hourly charge. Run `./cleanup.sh` when done testing.

## Alternative: Deploy via CloudFormation

`deploy.sh`/`cleanup.sh` above call the AWS CLI directly and aren't tracked in
any stack. `deploy-cfn.sh`/`cleanup-cfn.sh` do the same deployment through two
CloudFormation stacks instead — `hospital-scheduling-agent-ecr` (just the ECR
repo, so it exists before the image is pushed) and
`hospital-scheduling-agent-service` (IAM roles, cluster, ALB, task definition,
service) — defined in [`cloudformation/`](cloudformation/). This gets you
drift-visible, update-in-place, single-command teardown at the cost of the
CLI-native scripts' immediacy. New to ECS's cluster/service/task-definition/role
terminology? See [`cloudformation/ECS-CONCEPTS.md`](cloudformation/ECS-CONCEPTS.md).
Wondering why there's an ALB and two security groups? See
[`cloudformation/LOAD-BALANCER-AND-SECURITY-GROUPS.md`](cloudformation/LOAD-BALANCER-AND-SECURITY-GROUPS.md).

```bash
chmod +x deploy-cfn.sh cleanup-cfn.sh
./deploy-cfn.sh   # deploys the ECR stack, builds/pushes the image, deploys the service stack
./cleanup-cfn.sh  # deletes the service stack, then the ECR stack
```

Note the log group differs from the CLI path: `/ecs/hospital-scheduling-agent`
(not `/ecs/scheduling-agent`). Use only one deployment method at a time — both
create an ECR repo named `hospital-scheduling-agent` and will collide if run
together.

Each run of `deploy-cfn.sh` pushes the image under a fresh timestamp tag
(not `latest`) so the task definition's `Image` property always changes —
otherwise CloudFormation sees no diff on redeploy and silently leaves the old
task running. This means repeated deploys accumulate tagged images in ECR;
`./cleanup-cfn.sh` removes them all when you're done.
