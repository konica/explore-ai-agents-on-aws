# Fargate vs. EC2 Launch Type, and What an ENI Is

This project ships two ECS stacks for the same app — `ecs-service.yaml`
(Fargate) and `ecs-service-ec2.yaml` (EC2 launch type). Here's what actually
differs between them, and the networking concept (ENI) that both quietly
depend on.

## Fargate vs. EC2 launch type

Both use the same cluster/service/task-definition model — the difference is
**who manages the servers your tasks run on**.

| | **Fargate** (`ecs-service.yaml`) | **EC2 launch type** (`ecs-service-ec2.yaml`) |
|---|---|---|
| Compute | AWS-managed, no visible servers | An Auto Scaling Group of EC2 instances you own |
| What you manage | Only the task (`Cpu`/`Memory` per task) | The instances too: AMI, `InstanceType`, patching, capacity (`MinSize`/`MaxSize`/`DesiredCapacity`) |
| `TaskDefinition.RequiresCompatibilities` | `[FARGATE]` | `[EC2]` |
| `Service.LaunchType` | `FARGATE` | `EC2` |
| Extra resources needed | None beyond the task/service | `InstanceRole`, `InstanceProfile`, `InstanceSecurityGroup`, `LaunchTemplate`, `AutoScalingGroup` |
| `NetworkConfiguration.AssignPublicIp` | `ENABLED` (Fargate-only property) | Not set — EC2 launch type tasks can't use it; the *instance* gets the public IP instead, via the launch template |
| Billing | Per task, per second, for exactly the `Cpu`/`Memory` requested | Per EC2 instance-hour, regardless of how much of it your tasks actually use |
| First-deploy timing | Task starts as soon as Fargate allocates capacity | Nothing can run until an instance boots, its ECS agent starts, and it registers with the cluster — several extra minutes |
| Bin-packing | N/A — one task, one isolated environment | You decide how many tasks fit per instance; better utilization if tuned, wasted capacity if not |

Everything else — the ALB, both security groups, the `TargetGroup`, the
container image, the app code — is identical between the two stacks. That's
by design: swapping launch types shouldn't require rearchitecting anything
above the compute layer.

## What's an ENI, and why does it matter here?

An **Elastic Network Interface (ENI)** is a virtual network card in a VPC.
It's the thing that actually has an IP address, a MAC address, and security
groups attached to it — not the "instance" or "task" as a whole. Anything
with network presence in a VPC (an EC2 instance, a Lambda function in a
VPC, an ECS task) gets one via an ENI.

Normally you don't think about ENIs because each EC2 instance just has one
"primary" ENI and that's it — the instance and its network identity are the
same thing. Containers break that assumption: several containers can run on
one instance, and by default (Docker's `bridge` mode) they'd all share the
instance's single ENI and its IP, meated out via port mapping. ECS's
`awsvpc` network mode — used by **both** `ecs-service.yaml` and
`ecs-service-ec2.yaml` — instead gives **each task its own ENI**, as if it
were its own tiny instance on the network, with its own private IP address
and its own security group, regardless of what else is running alongside it.

## How ENIs show up in this stack specifically

- **`TargetType: ip` on `TargetGroup`**: the ALB registers targets by IP
  address, not by instance ID or host port. That's only possible because
  each task has its own ENI with its own IP — the ALB is really just
  routing to that ENI's address, whether it happens to belong to a
  Fargate-managed task or an EC2-launch-type one. This is exactly why the
  ALB/TargetGroup/Listener trio is identical between both stacks: from the
  ALB's point of view, a task's IP is a task's IP.
- **`EcsSecurityGroup` is attached to the *task's* ENI**, not to any host.
  In `ecs-service.yaml` (Fargate) that's the task's only ENI. In
  `ecs-service-ec2.yaml` it's a *second*, separate ENI from the EC2
  instance's own primary one — see next point.
- **On the EC2 stack, each instance ends up with two kinds of ENI**:
  1. The instance's own **primary ENI**, protected by `InstanceSecurityGroup`
     (no inbound rules — the instance doesn't need to accept traffic
     directly; it just needs outbound access to pull the image and reach
     Bedrock/CloudWatch).
  2. A separate **task ENI** per running task, protected by
     `EcsSecurityGroup` (inbound only from the ALB), that only exists while
     the task is running.

     This is only possible because the launch template's `UserData` sets
     `ECS_ENABLE_TASK_ENI=true` — this is the exact setting from the
     `CREATE_FAILED` debugging session that made the EC2-launch-type agent
     capable of attaching a second ENI per task in the first place. Without
     it, the instance can still join the cluster, but it can never host an
     `awsvpc`-mode task, because it has no way to hand out task-specific
     ENIs.
  3. Because task ENIs are real ENIs consuming a slot from the instance's
     ENI limit (which varies by instance type — e.g. `t3.medium` supports a
     handful), this is also what caps how many `awsvpc` tasks can run on a
     single EC2 instance — one more thing Fargate hides from you entirely,
     since AWS manages that allocation invisibly per task.

## Where to see this in code

- `ecs-service.yaml` / `ecs-service-ec2.yaml` — `TaskDefinition.NetworkMode: awsvpc` in both
- `ecs-service-ec2.yaml` — `LaunchTemplate`'s `UserData` (`ECS_ENABLE_TASK_ENI=true`), `InstanceSecurityGroup` vs. `EcsSecurityGroup`
- [`LOAD-BALANCER-AND-SECURITY-GROUPS.md`](LOAD-BALANCER-AND-SECURITY-GROUPS.md) — the ALB/security-group side of this same picture
