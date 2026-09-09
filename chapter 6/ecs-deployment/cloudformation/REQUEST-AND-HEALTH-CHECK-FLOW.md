# Request Data Flow and Health Checks

Companion to [`LOAD-BALANCER-AND-SECURITY-GROUPS.md`](LOAD-BALANCER-AND-SECURITY-GROUPS.md)
(which covers *why* the ALB and two security groups exist). This one covers
*how a request actually moves* through `Listener` → `TargetGroup` → a task,
and the separate health-check loops that decide whether a task gets traffic
at all.

## Request data flow: Listener → TargetGroup → task

CloudFormation creates `LoadBalancer` and `TargetGroup` independently (in
parallel — neither references the other), but at **request time** they form
a strict chain:

```
Client ──> LoadBalancer (public DNS, listens on port 80)
             │
             ▼
          Listener   ← the thing actually bound to port 80; receives every connection
             │  evaluates DefaultActions: forward to TargetGroup
             ▼
          TargetGroup   ← picks one currently-healthy registered target
             │
             ▼
     Task's ENI (private IP : ContainerPort)
```

1. **`LoadBalancer`** is the front door — it owns the public DNS name and
   the ENIs in your subnets that actually receive internet traffic. It
   doesn't decide anything about routing by itself.
2. **`Listener`** is bound to port 80 on the load balancer and receives
   every incoming connection first. It evaluates its rules — here just one
   `DefaultActions: [{Type: forward, TargetGroupArn: !Ref TargetGroup}]`, so
   every request is forwarded to that one target group (no path-based
   routing in this template).
3. **`TargetGroup`** holds the live, health-checked list of registered
   targets (task ENI IPs on `ContainerPort`, since `TargetType: ip`). It
   picks one *healthy* target (round-robin by default) and forwards the
   request to it.
4. The request lands on that **task's ENI** on `ContainerPort` (8080) —
   reachable only because `EcsSecurityGroup` allows inbound from
   `AlbSecurityGroup` on that port (see the security-groups doc).

So at request time the order is **Listener first, then TargetGroup** — the
Listener is the routing decision point, the TargetGroup is the target
selection point.

## Health checks: two independent loops, one endpoint

Both loops hit the same `/health` path, but they're performed by different
actors for different purposes, and either one can trigger a task
replacement on its own.

| | Container health check (`TaskDefinition.ContainerDefinitions[0].HealthCheck`) | Target group health check (`TargetGroup`) |
|---|---|---|
| Who performs it | The ECS agent, from *inside* the task's own network namespace | The ALB itself, from outside, over the network |
| How | `curl -f http://localhost:8080/health` — runs literally inside the container | An HTTP GET to the task's ENI IP on port 8080, path `/health` — exactly like a real client request |
| Settings | `Interval: 30`, `Timeout: 5`, `Retries: 3`, `StartPeriod: 60` (grace before failures count) | `HealthCheckIntervalSeconds: 30`, `HealthyThresholdCount: 2` (consecutive successes to mark healthy), `UnhealthyThresholdCount: 3` (consecutive failures to mark unhealthy) |
| On failure | ECS marks the task `UNHEALTHY` and replaces it — an internal decision, the ALB isn't involved | The ALB stops routing traffic to that target (deregisters it) — it does *not* kill the task by itself |

They check different things — "is the process alive from inside" vs. "can
a real request reach and be answered by this task from outside" — and can
disagree, e.g. if a security group or routing issue exists between the ALB
and the task's ENI even though the container itself is fine.

### The bridge between them: `HealthCheckGracePeriodSeconds: 120` on `Service`

This tells **ECS** (not the ALB): "for the first 120 seconds after a task
starts, ignore what the ALB is reporting about this task's health when
deciding whether to kill and replace it." It exists because a freshly
started task needs time to pull the image, boot the Strands agent, and
start responding — the container's own `StartPeriod` is 60s, and 120s adds
margin on top of that so ECS doesn't kill a task that's simply still
booting, which could otherwise crash-loop forever if startup ever takes
longer than one health-check cycle.

### Timeline

```
t=0s     Task starts. Registered with TargetGroup, but not yet receiving real traffic.
         Container HealthCheck's 60s StartPeriod begins (failures don't count yet).
         Service's 120s grace period begins (ECS ignores the ALB's verdict for this task).

t=30s+   Both checks start actually running (every 30s).
         ALB needs 2 consecutive successes before adding the target to real rotation.
         Container check needs to not fail 3 times in a row (once StartPeriod ends at t=60s).

t~60-90s Once both checks are passing: the task is (a) receiving real ALB-routed
         traffic, and (b) considered healthy by ECS.

t=120s+  Grace period ends. From now on, if the ALB reports this target unhealthy
         (3 consecutive failures), ECS also acts on that and replaces the task —
         not just stops routing to it.
```

If a task gets killed and replaced repeatedly right around the 2-minute
mark, that's this exact mechanism: the grace period expiring while the
ALB's check is still failing.

## Where to see this in code

In [`ecs-service.yaml`](ecs-service.yaml) (identical in
[`ecs-service-ec2.yaml`](ecs-service-ec2.yaml)):

- `Listener.Properties.DefaultActions` — the forwarding rule
- `TargetGroup.Properties.HealthCheck*` — the ALB-side health check
- `TaskDefinition.ContainerDefinitions[0].HealthCheck` — the container-side health check
- `Service.Properties.HealthCheckGracePeriodSeconds` — the bridge between the two
