# EKS Concepts: Cluster, Fargate Profile, IRSA, and Ingress

If you're coming from `ecs-deployment` (or new to EKS generally), the names
in `eks-cluster.yaml` and `deploy-cfn.sh` (`Cluster`, `FargateProfile`,
`PodExecutionRole`, IRSA, `Ingress`) map onto ECS concepts, but not
one-to-one. Here's how they relate, using the same restaurant analogy as
[`../../ecs-deployment/cloudformation/ECS-CONCEPTS.md`](../../ecs-deployment/cloudformation/ECS-CONCEPTS.md).

## The subnet gotcha that trips up everyone coming from ECS

ECS Fargate tasks can run in a **public** subnet (`AssignPublicIp: ENABLED`,
what `ecs-deployment` does). **EKS Fargate profiles cannot** —
`AWS::EKS::FargateProfile` rejects public subnets outright, failing with
`"...is not a private subnet"`. There's no flag to opt out of this; the pod's
subnet must have its default route through a NAT Gateway, not an Internet
Gateway. Since a default VPC's subnets are all public, `eks-network.yaml`
provisions a dedicated VPC with an actual public/private split and a NAT
Gateway before `eks-cluster.yaml` ever runs. (`deploy.sh`, the `eksctl`
path, doesn't hit this because `eksctl create cluster --fargate` already
provisions this same kind of dedicated VPC automatically.)

## The restaurant analogy

| EKS concept | Restaurant analogy | What it actually is | ECS equivalent |
|---|---|---|---|
| **Cluster** | The building, plus a shared front desk that reads every standing order | The managed Kubernetes control plane (API server, etcd). It schedules pods but isn't where your containers run. | Cluster (but ECS's cluster is a much thinner concept — just a namespace for tasks) |
| **Fargate Profile** | The rule "orders from the kitchen's West wing get made to-go, no dedicated cook station" | Tells EKS which pods — matched by namespace (and optionally labels) — run on serverless Fargate instead of needing an EC2 node group | The Fargate *launch type* on the ECS service |
| **Pod Execution Role** | The kitchen staff's ID badge to unlock supply closets | Permissions **Fargate itself** needs before your code starts — pulling the image from ECR, writing logs. Your application code never uses this role. | Task Execution Role |
| **IRSA Role** (IAM Role for a Kubernetes Service Account) | The chef's own permissions once cooking | Permissions **your application code inside the pod** uses at runtime — here, `bedrock:InvokeModel`. Granted per-`ServiceAccount` via a federated trust to the cluster's OIDC provider, not attached to the pod directly. | Task Role |
| **OIDC Provider** | The ID-verification kiosk that both the kitchen and city hall (IAM) trust | An IAM resource that trusts tokens issued by *this specific cluster*. Without it, IRSA has nothing to federate against. | *(no ECS equivalent — ECS tasks assume their Task Role directly, no federation needed)* |
| **Namespace** | A section of the kitchen | A logical grouping inside the cluster; Fargate profiles, RBAC, and network policy all key off it | *(closest to nothing — ECS has no sub-cluster grouping)* |
| **Deployment** | The standing order: "always have N dishes ready" | Keeps a desired number of pod replicas running from a pod template, replacing any that crash | Service (the "keep N running" part) |
| **Service** (Kubernetes) | The pass-through window between kitchen and waiter | A stable internal network identity + load balancing across a Deployment's pods | *(no direct ECS equivalent — ECS tasks register with the ALB target group directly)* |
| **Ingress** + AWS Load Balancer Controller | The maître d' who seats a walk-in guest and radios the kitchen | A Kubernetes object declaring "route external HTTP here"; the AWS Load Balancer Controller watches it and provisions/manages the real ALB and target group | The ECS service managing its ALB target group directly |

## The chain, top to bottom

```
Cluster (the building + front desk)
  └── Fargate Profile (default+kube-system, and one for our namespace)
        └── governs where pods from a namespace get serverless compute
  └── OIDC Provider
        └── lets IAM trust "system:serviceaccount:<namespace>:<name>" tokens
              └── IRSA Role → lets our agent's ServiceAccount call Bedrock (app-level)
  └── Namespace (scheduling-agent)
        └── Deployment (the standing order: "keep 1 pod running")
              └── uses → Pod Execution Role (infra-level: pull image, write logs)
              └── uses → ServiceAccount → IRSA Role (app-level: call Bedrock)
              └── produces → Pod(s) (the actual running container(s))
        └── Service (ClusterIP) → stable internal address for the Deployment's pods
        └── Ingress → tells the AWS Load Balancer Controller to provision an ALB
                        routing to the Service
```

## Why CloudFormation stops at the cluster

`eks-network.yaml` and `eks-cluster.yaml` manage everything that's a plain
*AWS* resource: the VPC/subnets/NAT Gateway, the cluster, Fargate profiles,
the two base IAM roles, and the OIDC provider. They deliberately do **not**
manage:

- The Kubernetes `Deployment`/`Service`/`Ingress` — CloudFormation has no
  resource types for Kubernetes API objects (unlike, say, AWS CDK's `eks`
  module, which ships a Lambda-backed custom resource that runs `kubectl`
  on your behalf).
- The two IRSA roles' trust policies — an IRSA trust policy's IAM
  `Condition` key must be the literal string `"<oidc-issuer-host>:sub"`.
  CloudFormation's intrinsic functions (`Fn::Sub`, `Fn::GetAtt`, ...)
  resolve template *values*, not JSON object *keys*, so there's no clean
  way to build that key from `Cluster.OpenIdConnectIssuerUrl` inside the
  template itself.

`deploy-cfn.sh` reads `OidcIssuerUrl` from this stack's outputs, strips the
`https://` prefix in plain bash, and creates those two IRSA roles with
`aws iam create-role` directly — the same way `eksctl create
iamserviceaccount` does internally (it also resolves the issuer first and
then generates a role with the key already baked in, rather than asking
CloudFormation to compute it).

## Where to see this in code

In [`eks-network.yaml`](eks-network.yaml):

- `PublicSubnet1` / `PublicSubnet2` — routed through the `InternetGateway`;
  host the NAT Gateway and (via their `kubernetes.io/role/elb` tag, which
  the AWS Load Balancer Controller auto-discovers) the ALB
- `PrivateSubnet1` / `PrivateSubnet2` — routed through the `NatGateway`;
  the only subnets `eks-cluster.yaml`'s Fargate profiles are allowed to use

In [`eks-cluster.yaml`](eks-cluster.yaml):

- `ClusterRole` — has the AWS-managed `AmazonEKSClusterPolicy`
- `FargatePodExecutionRole` — has the AWS-managed
  `AmazonEKSFargatePodExecutionRolePolicy`
- `Cluster` — the control plane, with
  `BootstrapClusterCreatorAdminPermissions: true` so the IAM principal
  running `deploy-cfn.sh` gets `kubectl` access with no extra
  `aws-auth` ConfigMap step
- `FargateProfileDefault` / `FargateProfileApp` — which namespaces get
  serverless compute, using `PrivateSubnetIds` from `eks-network.yaml`
- `OidcProvider` — what makes IRSA possible

In [`../deploy-cfn.sh`](../deploy-cfn.sh): the IRSA role creation, the
`ServiceAccount` manifests in [`../k8s/`](../k8s/), and the AWS Load
Balancer Controller Helm install all happen after this stack, using its
outputs.
