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
Want to know how a request actually flows through the Listener/TargetGroup,
or how the ALB and container health checks interact? See
[`cloudformation/REQUEST-AND-HEALTH-CHECK-FLOW.md`](cloudformation/REQUEST-AND-HEALTH-CHECK-FLOW.md).

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

### EC2 launch type variant

`deploy-cfn.sh`/`ecs-service.yaml` above run tasks on Fargate. `deploy-cfn-ec2.sh`/
`ecs-service-ec2.yaml` deploy the same app on the **EC2 launch type** instead —
tasks run on an Auto Scaling Group of EC2 container instances that you own,
rather than AWS-managed Fargate capacity. It reuses the same ECR
repo/image as the Fargate path (`hospital-scheduling-agent-ecr`) and deploys
into its own stack (`hospital-scheduling-agent-ec2-service`), so both variants
can run side by side without colliding. New to how the two launch types
differ, or what an ENI is and why both stacks depend on one per task? See
[`cloudformation/FARGATE-VS-EC2-AND-ENI.md`](cloudformation/FARGATE-VS-EC2-AND-ENI.md).

```bash
chmod +x deploy-cfn-ec2.sh cleanup-cfn-ec2.sh
./deploy-cfn-ec2.sh   # deploys/reuses the shared ECR stack, builds/pushes the image, deploys the EC2 service stack
./cleanup-cfn-ec2.sh  # deletes only the EC2 service stack (leaves the shared ECR stack for the Fargate variant)
```

Differences worth knowing:

- **Cost model**: EC2 instances bill per-hour whether idle or busy (default
  `t3.medium`, ~1 running instance), unlike Fargate's per-second-per-task
  billing. Run `./cleanup-cfn-ec2.sh` when you're done, or scale `MinSize`
  down, to stop paying for idle instances.
- **First-deploy timing**: an instance has to boot, join the cluster, and
  only then can a task place onto it — expect the service to take a few
  minutes longer to stabilize than the Fargate path, especially on the very
  first deploy.
- **Instance access**: instances are reachable via AWS Systems Manager
  Session Manager (no SSH key pair, no open inbound port) if you need to
  inspect one directly — `aws ssm start-session --target <instance-id>`.

Once both stacks are torn down, run `./cleanup-cfn.sh` to remove the shared
ECR repository stack.
