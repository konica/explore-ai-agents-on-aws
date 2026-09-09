# Load Balancer and Security Groups: Why Two of Each

`ecs-service.yaml` creates one Application Load Balancer (ALB) and *two*
security groups. Here's why both exist and how they fit together.

## Why a Load Balancer at all?

Fargate tasks don't have a stable address. Every time ECS replaces a task —
a deploy, a crash restart, a scale-out — it gets a **brand-new private IP**.
If clients pointed directly at a task's IP, that link would break on the
next deployment.

The ALB gives you:

1. **One stable public DNS name**
   (`hospital-scheduling-agent-alb-....elb.amazonaws.com`) that never changes,
   no matter how many times tasks get replaced underneath it.
2. **Health checking** — the ALB polls each task's `/health` endpoint and
   only routes traffic to tasks that respond healthy, automatically pulling
   a crashed/unhealthy task out of rotation.
3. **Load spreading** — if `DesiredCount` were more than 1, the ALB
   distributes requests across all running tasks instead of clients having
   to track which task to hit.

Without it, you'd need to manually track and re-share the task's current IP
every time it changed — not viable.

## Why two separate security groups instead of one?

A security group is a firewall attached to a specific network interface. The
ALB and the ECS task are two *different* network interfaces, so they can
(and should) have different rules.

| Security group | Attached to | Ingress rule | Why |
|---|---|---|---|
| `AlbSecurityGroup` | The ALB (`LoadBalancer.Properties.SecurityGroups`) | TCP 80 from `0.0.0.0/0` | The ALB *must* be reachable from anywhere on the internet — that's its whole job |
| `EcsSecurityGroup` | The Fargate task's network interface, via `Service.Properties.NetworkConfiguration.AwsvpcConfiguration.SecurityGroups` | TCP `ContainerPort` (8080) only from `AlbSecurityGroup` | The task itself should never be reachable directly from the internet |

Note the ECS rule's source is `SourceSecurityGroupId: !Ref AlbSecurityGroup` —
not a CIDR range, but a *reference to the other security group's ID*. That
means "only allow traffic from something that belongs to the ALB's security
group in," not "allow traffic from any IP in some range."

Neither security group has an explicit `SecurityGroupEgress`, so both keep
the AWS default egress rule — allow all outbound traffic anywhere. That's why
the task can still reach Bedrock, ECR, and CloudWatch Logs even though
nothing explicitly opened those outbound paths.

If you used one shared security group for both, you'd be stuck choosing
between two bad options: open port 8080 to the whole internet too (defeating
the purpose of putting a load balancer in front of it), or leave the ALB
unable to reach the task at all. Splitting them lets the ALB be public while
the application container stays reachable only through it — even though in
this lab config the task also happens to sit in a public subnet with a
public IP (`AssignPublicIp: ENABLED`); it's the security group, not the
subnet placement, that actually blocks direct internet access to the task.

## Putting it together

```
Internet ──80──> ALB (AlbSecurityGroup: 0.0.0.0/0:80)
                   │
                   ▼ forwards via Listener → TargetGroup
Fargate task ENI (EcsSecurityGroup: 8080 only from AlbSecurityGroup)
```

The `TargetGroup` and `Listener` resources don't have security groups of
their own — they're logical ALB routing constructs, not network interfaces,
so they don't need one.

## Where to see this in code

In [`ecs-service.yaml`](ecs-service.yaml):

- `AlbSecurityGroup` / `EcsSecurityGroup` — the two security groups and their
  ingress rules
- `LoadBalancer` — attaches `AlbSecurityGroup`
- `Service` — attaches `EcsSecurityGroup` via `NetworkConfiguration` (not the
  `TaskDefinition`; with Fargate's `awsvpc` networking mode, each task gets
  its own ENI, and the security groups for that ENI come from the service's
  — or a standalone task's — network configuration)
- `TargetGroup` / `Listener` — the ALB's routing rules that connect the two
