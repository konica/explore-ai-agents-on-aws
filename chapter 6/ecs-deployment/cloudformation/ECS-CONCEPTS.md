# ECS Concepts: Cluster, Service, Task Definition, and the Two Roles

If you're new to ECS, the names in `ecs-service.yaml` (`Cluster`, `Service`,
`TaskDefinition`, `ExecutionRole`, `TaskRole`) can be confusing. Here's how
they relate, using a restaurant analogy.

## The restaurant analogy

| ECS concept | Restaurant analogy | What it actually is |
|---|---|---|
| **Cluster** | The restaurant building | A logical grouping/namespace where your containers run. It doesn't do much by itself — it's where services and tasks live. |
| **Task Definition** | The recipe | A blueprint: what container image to run, how much CPU/memory it gets, what port it listens on, what environment variables it needs, where its logs go. It's not running anything — it's just instructions. |
| **Task** | One cooked dish, made from the recipe | An actual *running instance* of the task definition — one live container. You don't define this directly; the service creates it. |
| **Service** | The standing order to "always have N dishes ready" | Keeps a desired number of tasks running from a task definition, restarts them if they crash, and registers them with the load balancer. |
| **Task Execution Role** | The kitchen staff's ID badge to unlock supply closets | Permissions **ECS itself** needs on your behalf *before your code even starts* — pulling the Docker image from ECR, writing logs to CloudWatch. Your application code never uses this role directly. |
| **Task Role** | The chef's own permissions once cooking | Permissions **your application code inside the container** uses at runtime — in this project, calling `bedrock:InvokeModel` to talk to Claude. This is the identity your Python code actually assumes. |

## The chain, top to bottom

```
Cluster (the building)
  └── Service (the standing order: "keep N tasks running")
        └── uses → Task Definition (the recipe)
                      ├── Execution Role → lets ECS pull the image + write logs (infra-level)
                      └── Task Role       → lets your agent code call Bedrock (app-level)
        └── produces → Task(s) (the actual running container(s))
```

## Why two separate roles instead of one?

Least privilege: the thing that pulls your image and writes logs doesn't need
Bedrock access, and your agent code doesn't need ECR/CloudWatch permissions.
Splitting them means if your application code is ever compromised, the blast
radius is limited to `bedrock:InvokeModel`, not "can also read/write your logs
or registry."

## Where to see this in code

In [`ecs-service.yaml`](ecs-service.yaml):

- `ExecutionRole` — has the AWS-managed `AmazonECSTaskExecutionRolePolicy`
- `TaskRole` — has the custom `BedrockAccess` inline policy, scoped to
  `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` only
- `Cluster` — the namespace
- `TaskDefinition` — references both roles and the container image
- `Service` — ties the cluster, task definition, and load balancer together,
  and keeps `DesiredCount` tasks running
