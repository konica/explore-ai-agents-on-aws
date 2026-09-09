# EKS (Fargate) Deployment: Hospital Scheduling Agent

A Strands agent deployed on Amazon EKS, running on an EKS Fargate profile
(no worker nodes to manage) and exposed through an Application Load Balancer
via the AWS Load Balancer Controller. The agent coordinates surgical
scheduling by checking provider availability, equipment needs, and operating
room schedules.

This is an EKS port of [`../ecs-deployment`](../ecs-deployment) — the
containerized FastAPI + Strands app is unchanged; only the deployment
target moved from ECS Fargate to EKS Fargate.

## Architecture

```
Browser (chat UI) → ALB (Ingress, AWS LB Controller) → Service → Pod (EKS Fargate) → Bedrock (Claude)
                                                                       ↓
                                                                 FastAPI + Strands Agent
                                                                 (tools: provider calendar,
                                                                  equipment check, booking)
```

- **Compute**: an EKS Fargate profile runs the agent's pod — there's no EC2
  node group to size, patch, or scale.
- **IAM**: the pod authenticates to Bedrock via IRSA (IAM Roles for Service
  Accounts) — the Kubernetes equivalent of the ECS task role.
- **Ingress**: the AWS Load Balancer Controller watches the `Ingress` object
  and provisions/manages the ALB and target group, the same way ECS manages
  them directly for the Fargate service.

## Prerequisites

- AWS account with credentials configured (`aws sts get-caller-identity`)
- Docker installed and running (`docker info`)
- Amazon Bedrock model access enabled for Claude Sonnet (Anthropic) in us-east-1
- AWS CLI v2 (`aws --version`)
- [`eksctl`](https://eksctl.io) (cluster and Fargate profile lifecycle, IRSA)
- `kubectl`
- `helm` (installs the AWS Load Balancer Controller)
- `envsubst` (ships with `gettext`; on macOS: `brew install gettext`)

## Deploy

```bash
chmod +x deploy.sh cleanup.sh
./deploy.sh
```

The script creates: ECR repo, Docker image, the EKS cluster and Fargate
profile, the AWS Load Balancer Controller, IAM roles (IRSA), and the
Deployment/Service/Ingress. Unlike ECS Fargate, an EKS cluster's control
plane takes real time to provision — **first run is roughly 15-20 minutes**;
later redeploys (same cluster, new image) take 2-3 minutes.

On Windows, run from WSL or Git Bash.

## Test

Once the ALB is healthy, open its address in your browser:

```
http://<ALB_DNS>
```

You'll see a chat interface where you can type scheduling requests or click
one of the suggestion buttons. `deploy.sh` prints the ALB DNS name at the end
once it becomes available.

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
kubectl logs -n scheduling-agent -l app=hospital-scheduling-agent --follow
```

## Clean Up

```bash
./cleanup.sh
```

Removes all AWS resources: the Ingress/Service/Deployment (so the ALB
Controller tears down the ALB and target group first), the Load Balancer
Controller, IRSA service accounts, the Fargate profile, the EKS cluster,
and the ECR repo. The `AWSLoadBalancerControllerIAMPolicy` IAM policy is
left in place since other clusters in the account may depend on it.

## Cost

EKS bills the control plane at a flat rate (~$0.10/hour) regardless of
load, on top of Fargate's per-second vCPU/memory pricing for the pod
(same ~$0.05/hour as the ECS version at the default 1 vCPU / 2 GB). The
ALB adds a small hourly charge. Run `./cleanup.sh` when done testing —
an idle EKS cluster still bills for the control plane.

## What changed vs. `ecs-deployment`

| | ECS Fargate | EKS Fargate |
|---|---|---|
| Compute unit | ECS task | Kubernetes pod |
| Scheduling | ECS service | Kubernetes Deployment |
| Serverless compute | Fargate launch type | Fargate profile |
| Task/pod IAM | ECS task role | IRSA (IAM role for a Kubernetes service account) |
| Load balancing | ECS service manages the ALB target group directly | AWS Load Balancer Controller watches an `Ingress` object |
| Manifests | inline JSON in `deploy.sh` | YAML files in [`k8s/`](k8s/), templated with `envsubst` |

`Dockerfile`, `app/`, and `requirements.txt` are identical to
`ecs-deployment` — the container doesn't know or care which orchestrator is
running it.
