# Writing `template.yaml` for AWS SAM

## SAM vs. CloudFormation: how they relate

**CloudFormation is the actual AWS service that creates infrastructure.** You write a
template describing resources — `AWS::Lambda::Function`, `AWS::S3::Bucket`,
`AWS::IAM::Role`, etc. — and CloudFormation creates/updates/deletes all of them
together as one unit called a "stack." It's the foundation everything else in this
project sits on.

**SAM is a shorthand layer on top of CloudFormation**, purpose-built for serverless
apps (Lambda, API Gateway, DynamoDB, Step Functions). Raw CloudFormation for a
Lambda-behind-an-API is verbose — you'd hand-write the function, its execution role,
the API Gateway REST API, the deployment, the stage, and the Lambda permission letting
API Gateway invoke it. SAM lets you write one shorthand block instead.

Look at this project's `template.yaml`:

```yaml
DocumentAnalysisFunction:
  Type: AWS::Serverless::Function
```

`AWS::Serverless::Function` **is not a real CloudFormation resource type** —
CloudFormation has no idea what it is on its own. That's what the top-of-file
`Transform` line is for:

```yaml
Transform: AWS::Serverless-2016-10-31
```

This `Transform` tells CloudFormation: "before you do anything, run this template
through the SAM macro first." The macro expands the one `AWS::Serverless::Function`
block (plus its `Events: Api` block) into the *actual* underlying CloudFormation
resources: an `AWS::Lambda::Function`, an `AWS::IAM::Role` built from the `Policies`
list, an `AWS::ApiGateway::RestApi`, a deployment/stage, and the permission letting
API Gateway call the function. Only *then* does CloudFormation deploy it.

So a SAM template is just a CloudFormation template with a shorthand vocabulary and
one extra line that unlocks it. `sam build`/`sam deploy` are convenience tooling on
top: `sam build` compiles the container image, `sam deploy` uploads it to a staging
S3 bucket (and ECR for the image) — this is the managed `aws-sam-cli-managed-default`
bucket referenced by `deploy.sh`'s `--resolve-s3` flag — then hands the expanded
template to CloudFormation to actually provision things. To see the fully-expanded raw
CloudFormation for a deployed stack, run:

```bash
aws cloudformation get-template --stack-name lambda-document-analysis-agent
```

## Why `deploy.sh` creates three CloudFormation stacks

Running `deploy.sh` leaves behind **three** stacks in CloudFormation, not one. Checking
a real account after a deploy shows the creation order:

| # | Stack | Created by | Contents |
|---|-------|-----------|----------|
| 1 | `aws-sam-cli-managed-default` | the `--resolve-s3` flag | `AWS::S3::Bucket` — staging bucket for uploaded artifacts |
| 2 | `<stack-name>-<hash>-CompanionStack` | the `--resolve-image-repos` flag | `AWS::ECR::Repository` — holds the Lambda's container image |
| 3 | `<stack-name>` (this project's actual app) | `--stack-name` + `template.yaml` | `DocumentAnalysisFunction`, its IAM role/permission, `DocumentBucket`, and the API Gateway REST API/deployment/stage |

`deploy.sh` passes both `--resolve-s3` and `--resolve-image-repos` to `sam deploy`
instead of pointing at pre-existing buckets/repos. Each flag means "if I don't have a
place to stage this yet, create one for me first" — and each one it has to create
becomes its own stack, built *before* the app stack that depends on it:

1. **`--resolve-s3`** — SAM CLI checks for the managed staging bucket
   (`aws-sam-cli-managed-default`). If missing, it creates that stack first: it needs
   somewhere to upload the packaged template/artifacts before anything else can happen.
2. **`--resolve-image-repos`** — this template's function uses `PackageType: Image` (a
   container, not a zip), so SAM CLI needs an ECR repo to push the image to. If none
   exists for this function, it auto-creates a "Managed ECR Repo Stack" — the
   `...CompanionStack` (confirmed by its own `Description`:
   `"AWS SAM CLI Managed ECR Repo Stack"`). It's named after the function's logical ID
   hash because SAM ties one companion repo to one function.
3. **Only once both exist** does SAM CLI build+push the image to the ECR repo, upload
   the transformed template to the S3 bucket, and finally deploy the actual app —
   `template.yaml`'s own stack, created last.

So the dependency chain is: staging bucket → image repo → application stack. Stacks 1
and 2 are SAM CLI's own bootstrap infrastructure — reusable across *any* SAM app
deployed later in the same account/region, which is why deleting
`aws-sam-cli-managed-default` is safe (SAM CLI just recreates it on the next deploy).
Stack 3 is the only one this project's code actually defines, and the only one
`cleanup.sh` tears down.

## When to use SAM vs. plain CloudFormation

SAM and CloudFormation aren't really either/or — a SAM template *is* a CloudFormation
template, and `Resources:` accepts plain CFN resource types right alongside
`AWS::Serverless::*` ones. The real question is whether SAM's shorthand and tooling
earn their keep for a given project.

### Use SAM when the workload is Lambda-centric

SAM earns its keep specifically around serverless compute — Lambda, API Gateway, Step
Functions, EventBridge rules, DynamoDB tables, SQS/SNS triggers. That's exactly this
project's `template.yaml` (Lambda + API Gateway), which is why it's a good fit here:

- **Less boilerplate** — `AWS::Serverless::Function` + an `Events: Api` block replaces
  the Lambda function, IAM role, API Gateway REST API, deployment, stage, and invoke
  permission you'd otherwise hand-write (see the expansion described above).
- **Policy Templates** — `Policies: [S3ReadPolicy: {...}]` instead of writing out IAM
  statements by hand (this template uses that for `DocumentBucket`).
- **Local testing without deploying** — `sam local invoke`, `sam local start-api`,
  `sam local start-lambda` emulate Lambda/API Gateway on your machine.
- **Fast dev-loop iteration** — `sam sync --watch` pushes code changes in seconds
  without a full CloudFormation update. Dev-only: it bypasses CloudFormation's safety
  checks, so never use it for anything you'd call production.
- **Built-in observability helpers** — `sam logs`, `sam traces` tail CloudWatch/X-Ray
  without leaving the CLI.
- **Rapid prototyping / learning**, like this book chapter — a working
  Lambda-behind-API-Gateway app in ~60 lines instead of ~300.

### Drop to raw CloudFormation when...

1. **Most of the resources aren't serverless.** VPCs, subnets, route tables, EC2
   fleets, RDS/Aurora clusters, ECS/EKS, Transit Gateway, load balancers, multi-account
   IAM — none of these have a SAM shorthand, so you're writing plain CloudFormation
   resource types regardless. At that point `Transform` buys nothing and just adds a
   layer of macro-expansion "magic" for readers to understand. If Lambda is a small
   piece bolted onto an otherwise non-serverless stack, keep the whole template in
   plain CloudFormation (or CDK) rather than pulling in SAM for one function.
2. **StackSets or cross-account/cross-region orchestration are needed.** SAM CLI has
   no concept of StackSets — that's CloudFormation-only tooling.
3. **The org restricts CloudFormation transforms/macros.** `Transform:
   AWS::Serverless-2016-10-31` is a public, AWS-managed macro CloudFormation invokes at
   deploy time. Some tightly regulated environments restrict which transforms are
   allowed to run; raw CloudFormation sidesteps the question entirely.
4. **Exact control over generated resources is required.** SAM's expansion is
   opinionated — e.g. it auto-names the API Gateway stage by convention, and
   `AutoPublishAlias` adds implicit Lambda versioning/alias behavior. When a property
   the shorthand doesn't expose is needed (a specific IAM role name, a custom API
   Gateway deployment strategy, etc.), write the underlying
   `AWS::Lambda::Function`/`AWS::IAM::Role`/`AWS::ApiGateway::*` resources directly —
   this can be done in the *same* template, mixed with SAM resources, since SAM is
   additive.
5. **The rest of the infrastructure is already on CDK (or Terraform).** Consistency
   beats a marginally shorter Lambda definition — CDK's `NodejsFunction`/
   `PythonFunction` L2 constructs give similar boilerplate reduction with the tool
   already in use for VPCs, databases, etc. Don't mix SAM in just for the Lambda
   pieces.
6. **There's no Lambda/serverless compute at all** — e.g. a template that's purely S3 +
   CloudFront + Route 53 for a static site. `Transform` and the SAM CLI toolchain
   (SAM CLI installed, a `sam build` step, the managed staging bucket/ECR repo covered
   above) add operational surface area for zero benefit when there's no function to
   build or emulate locally.

**Rule of thumb:** SAM when the deployable unit is "a Lambda function and its direct
triggers," CloudFormation (or CDK) when it's "a mix of infrastructure where Lambda is
just one resource among many."

## AWS's equivalent of an Azure Resource Group

Coming from Azure, "delete the Resource Group and everything in it goes away" maps to
**the CloudFormation stack** — with one important difference.

When `cleanup.sh` runs `sam delete`, it deletes the CloudFormation stack
`lambda-document-analysis-agent`. That one action tears down the Lambda function, its
IAM role, the API Gateway REST API, and the `DocumentBucket` S3 bucket — every
resource the stack owns — automatically, in dependency order. That's the same
"delete the container, everything inside goes with it" behavior as an Azure Resource
Group deletion.

**The difference:** an Azure Resource Group is a *mandatory, flat, retroactive*
container — every resource belongs to exactly one RG regardless of what tool created
it, and resources can be assigned into any RG after the fact. A CloudFormation stack
is not like that:

- A stack only contains resources CloudFormation itself created for that stack (or
  that were explicitly `import`ed into it — a deliberate extra step, not automatic).
- Plenty of AWS resources belong to no stack at all — anything created via the
  console, CLI, or another tool just exists loose in the account/region.
- So AWS's grouping is opt-in per deployment, not "every resource lives in a group."

### A naming trap to avoid

AWS also has a service literally called **"Resource Groups"** (under Resource Groups &
Tag Editor) — don't confuse it with Azure's. AWS Resource Groups are just a saved
tag-based or stack-based *view* for the console/CLI (e.g. "show me everything tagged
`Project=agent-demo`"). **Deleting an AWS Resource Group does not delete the
underlying resources** — it only deletes the saved grouping definition. This is the
opposite of what the name suggests to someone coming from Azure.

### Other ways people simulate "delete everything together" on AWS

- **Tags + `resourcegroupstaggingapi`** — tag everything with a common
  `Project`/`Environment` tag, then script a delete loop over `get-resources` results.
  Not atomic or dependency-aware like a stack delete — ordering is on you.
- **A separate AWS account per project/environment** — note "account" here means an
  **AWS account** (the whole billing/ownership container, identified by a 12-digit ID
  like `685394474162` in `aws sts get-caller-identity`'s output), *not* an **IAM user**
  like `poweruser` from that same output. Those are different things: an IAM user is
  just a login/credential inside one AWS account; every resource it creates is owned
  by that AWS account, not by the IAM user. Deleting the IAM user `poweruser` deletes
  nothing it created — the Lambda function, S3 buckets, and CloudFormation stacks stay
  exactly as they are, since they belong to account `685394474162` regardless of which
  IAM user's credentials were used to create them. The only way to make an entire AWS
  account's resources disappear is to close **the account itself** (Settings → Close
  Account) — a distinct action from removing an IAM user, and one no IAM user (not
  even the root user) can undo once its 90-day grace period ends. Many orgs (via AWS
  Organizations / Control Tower) spin up a disposable *account* per environment for
  exactly this reason: "close the account" is the RG-delete equivalent at that
  granularity — an entire environment's worth of infrastructure, not a single app.

**Bottom line for this project:** think of `template.yaml` (one CloudFormation stack)
as the "resource group" — that's the granularity where AWS gives atomic,
dependency-ordered create/delete, which is why `cleanup.sh` only needs one
`sam delete` call to remove everything the app stack owns.

## Deleting a stack without `sam delete`

For a "normal" CloudFormation stack — one not deployed through SAM, or when the raw
command is wanted instead of `sam delete`'s wrapper — use CloudFormation's delete API
directly.

**CLI:**

```bash
aws cloudformation delete-stack --stack-name lambda-document-analysis-agent --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name lambda-document-analysis-agent --region us-east-1
```

`delete-stack` returns immediately (deletion is asynchronous); the `wait` call blocks
until it's fully gone, the way `sam delete` appears to do synchronously.

**Console:** CloudFormation → Stacks → select the stack → Delete → confirm.

**CDK:** `cdk destroy <stack-name>` (or `cdk destroy --all`) — CDK's own wrapper around
the same `delete-stack` API, the same relationship CDK has to CloudFormation that
`sam delete` has.

### Two things `sam delete` handles that raw `delete-stack` doesn't

1. **Non-empty S3 buckets fail to delete.** `DocumentBucket` in this project's
   `template.yaml` has no `DeletionPolicy`, so CloudFormation will try to delete it —
   but it refuses if the bucket still has objects in it. Uploading anything through the
   API before tearing down would leave that resource stuck in `DELETE_FAILED`; empty it
   first with `aws s3 rm s3://<bucket-name> --recursive` and retry.
2. **It doesn't touch the ECR CompanionStack.** `delete-stack` on the app stack alone
   leaves `lambda-document-analysis-agent-<hash>-CompanionStack` (the managed ECR repo
   from the three-stacks section above) behind. `sam delete` deletes it too, after
   prompting to confirm removing the container images inside. To replicate manually:
   ```bash
   aws ecr batch-delete-image --repository-name <repo-name> --image-ids imageTag=latest --region us-east-1
   aws cloudformation delete-stack --stack-name lambda-document-analysis-agent-<hash>-CompanionStack --region us-east-1
   ```
   (ECR repos with images refuse to delete until emptied — same rule as S3 buckets.)

For a plain app stack with no S3/ECR resources holding data, `aws cloudformation
delete-stack` is a complete drop-in replacement for `sam delete`. For this project
specifically, `sam delete` does real cleanup work beyond the bare CloudFormation call.

## How the CLIs relate: `aws`, `sam`, `cdk`, `boto3`, and CloudFormation

These are four different tools that all ultimately talk to the same underlying AWS
APIs — they're layers, not competitors:

```
boto3 (Python SDK)  ─┐
aws CLI              ├──► raw AWS service APIs (CloudFormation, Lambda, S3, ECR, ...)
sam CLI             ─┤        ▲
cdk CLI             ─┘        │
                   (both sam and cdk ultimately call CloudFormation's
                    CreateStack/UpdateStack/DeleteStack APIs for you)
```

- **`aws` (AWS CLI)** — the general-purpose, low-level command-line client for *every*
  AWS service. `aws cloudformation deploy`, `aws s3 cp`, `aws lambda invoke` — one
  subcommand per API action, on any service, with no opinions about how you organize
  infrastructure. Everything else in this list is built on top of the same APIs the
  `aws` CLI exposes directly.
- **`boto3`** — the AWS SDK **for Python**. Same relationship as the `aws` CLI (direct,
  unopinionated access to every AWS service API), but called from Python code instead
  of a shell — `boto3.client("cloudformation").delete_stack(...)` instead of
  `aws cloudformation delete-stack`. Other languages have their own SDKs (`boto3` is
  Python-specific; JavaScript/Java/Go/etc. have their own).
- **`sam` CLI** — a higher-level tool specifically for serverless apps (see "SAM vs.
  plain CloudFormation" above). It doesn't replace CloudFormation; `sam build` packages
  code/images, and `sam deploy`/`sam delete` **generate a CloudFormation template and
  call the CloudFormation APIs for you** (via the same mechanism the `aws` CLI or
  `boto3` would use), plus manage the extra bootstrap stacks (staging bucket, ECR
  companion stack) covered earlier.
- **`cdk` CLI** — a higher-level tool for **any** AWS infrastructure (not just
  serverless), where the template is *generated from real code* (TypeScript, Python,
  Java, etc.) instead of written as YAML/JSON directly. `cdk synth` renders that code
  into a CloudFormation template; `cdk deploy`/`cdk destroy` then call the same
  CloudFormation APIs as `sam` or the `aws` CLI to actually create/delete resources.

**The common thread:** CloudFormation is the actual state-tracking, resource-creating
engine underneath all of them. `aws` and `boto3` talk to it (and every other AWS
service) directly and generically. `sam` and `cdk` are both convenience layers that
generate a CloudFormation template on your behalf and then drive the same
CloudFormation APIs — they differ in *how* you author that template (SAM: YAML
shorthand for serverless resources; CDK: general-purpose code for anything), not in
what actually deploys it.

## Practicing safely: avoid the Console wizard trap

For small hands-on projects, the biggest source of "I don't know what I created" is
the Console's **Create/Launch wizards**, not the services themselves. Launching an EC2
instance through the Console, for example, silently creates a security group, maybe a
key pair, an EBS volume, an ENI — because the *wizard* decides what's needed on your
behalf, and terminating the instance later doesn't know to undo those side-decisions.

**The fix: only create resources through CloudFormation (or SAM, when it's
Lambda-centric — see "SAM vs. plain CloudFormation" above), never through a Console
"Create/Launch" wizard.** A CloudFormation template has no hidden behavior — every
resource must be explicitly declared in `Resources:`, nothing appears that wasn't
written there, and `delete-stack` removes exactly what the stack owns. It also doubles
as documentation: reading the template tells you everything that exists, instead of
having to remember what a wizard did on your behalf weeks earlier.

### The workflow

1. Write a small `template.yaml` per experiment (e.g. an EC2 instance + security group,
   with every resource explicitly listed under `Resources:`).
2. `aws cloudformation deploy --template-file template.yaml --stack-name my-experiment --capabilities CAPABILITY_IAM`
3. When done: `aws cloudformation delete-stack --stack-name my-experiment` (+
   `aws cloudformation wait stack-delete-complete ...`).

Same two commands every time, regardless of what's inside — no need to remember
whether a given experiment quietly created a VPC, an Elastic IP, or a CloudWatch
alarm, because it's all sitting in the file that was written.

### A built-in safety net, regardless of tool

CloudFormation automatically tags every resource it creates with
`aws:cloudformation:stack-name`. `aws cloudformation list-stack-resources
--stack-name X` always shows the complete, authoritative list of what a stack owns,
and the Console's **Tag Editor** can search a whole account for anything *not* tagged
to a stack — a good periodic check for stragglers left over from before adopting this
habit.

### If raw CloudFormation feels tedious for something like EC2 + networking

That's exactly the case **AWS CDK** is built for (same idea as "SAM vs. plain
CloudFormation" above, just generalized beyond serverless): its L2 `ec2.Instance`
construct gives sensible, secure defaults with far less boilerplate than hand-writing
the VPC/security-group/EBS resources, while still compiling down to one CloudFormation
stack with the same atomic `cdk deploy`/`cdk destroy`. Worth learning once comfortable
with the raw-CloudFormation mental model — not a prerequisite for the atomic-cleanup
benefit above.

## How SAM finds this file

`sam build`, `sam deploy`, `sam validate`, and `sam local invoke` all auto-discover
`template.yaml` (or `template.yml` / `template.json`) in the current directory — that's
why `deploy.sh` in this folder just runs `sam build` / `sam deploy` without a `-t` flag.
Point at a different file with `-t` / `--template-file`, e.g.:

```bash
sam build -t template.yaml
```

## Syntax skeleton

A SAM template is a CloudFormation template with one required extra line (`Transform`)
plus SAM-specific resource types:

```yaml
AWSTemplateFormatVersion: '2010-09-09'   # optional, CFN convention
Transform: AWS::Serverless-2016-10-31    # REQUIRED — marks it as a SAM template

Description: string                     # optional

Parameters:                             # optional — input values (like Architecture in this template)
  MyParam:
    Type: String
    Default: foo
    AllowedValues: [foo, bar]

Mappings: { ... }                       # optional — static lookup tables
Conditions: { ... }                     # optional — conditional resource creation

Globals:                                # optional, SAM-only — shared defaults
  Function:
    Timeout: 900
    MemorySize: 1024

Resources:                              # REQUIRED
  MyFunction:
    Type: AWS::Serverless::Function     # SAM resource type (transforms into Lambda + Role + …)
    Properties:
      PackageType: Image | Zip
      CodeUri: ./src                    # for Zip
      Handler: app.lambda_handler        # for Zip
      Runtime: python3.13               # for Zip
      Architectures: [arm64]
      Environment:
        Variables: { KEY: value }
      Policies:                         # SAM policy templates or inline IAM statements
        - S3ReadPolicy: { BucketName: !Ref MyBucket }
      Events:                           # triggers — API Gateway, S3, SQS, EventBridge, etc.
        MyApi:
          Type: Api
          Properties: { Path: /foo, Method: post }
    Metadata:                           # required for PackageType: Image
      Dockerfile: Dockerfile
      DockerContext: ./src
      DockerTag: v1

Outputs:                                # optional
  MyOutput:
    Value: !Ref MyFunction
```

Everything under `Resources` / `Outputs` / `Parameters` accepts normal CloudFormation
intrinsic functions (`!Ref`, `!Sub`, `!GetAtt`, `!Join`, etc.) — SAM just adds the
`AWS::Serverless::*` shorthand types (`Function`, `Api`, `HttpApi`, `SimpleTable`,
`StateMachine`, `LayerVersion`, `Connector`, `Application`) that expand into full
CloudFormation resource sets at deploy time.

### `Metadata.Dockerfile` for image-based functions

For `PackageType: Image` functions, `Dockerfile` is just a **filename** — it's
resolved as `<DockerContext>/<Dockerfile>`. That means the Dockerfile must live
directly inside the directory `DockerContext` points to, and that directory is the
Docker build context: it must contain the Dockerfile plus everything its `COPY`/`ADD`
instructions reference. This project keeps `Dockerfile`, `app.py`, and
`requirements.txt` together in `src/` for exactly that reason.

## Common CloudFormation intrinsic functions

SAM templates are CloudFormation templates, so the standard intrinsic functions work
anywhere under `Resources` / `Outputs` / `Parameters`. The most common ones, using
examples from this project's own `template.yaml`:

### `!Ref`

Returns a value depending on what you reference:
- **Parameter** → the value passed in (or its default).
- **Resource** → a resource-specific "primary" value — usually the physical ID, but
  SAM resources sometimes return something more useful (e.g. `!Ref` on an
  `AWS::Serverless::Function` returns the Lambda function's ARN).

```yaml
Architectures:
  - !Ref Architecture          # → "arm64" or "x86_64" (the Parameter value)
...
- S3ReadPolicy:
    BucketName: !Ref DocumentBucket   # → the bucket's physical name
```

Full (non-shorthand) form is `Ref: Architecture` — note it's `Ref`, not `Fn::Ref`;
it's the one intrinsic function without an `Fn::` prefix.

### `!GetAtt`

Returns a **specific attribute** of a resource — for anything beyond what `!Ref`
gives you (ARN, endpoint, DNS name, etc.). Shorthand: `!GetAtt LogicalName.AttributeName`.
Full form: `Fn::GetAtt: [LogicalName, AttributeName]`. Available attributes are
resource-type-specific — check the "Return values" section of each resource's
CloudFormation docs page. Example: `!GetAtt DocumentBucket.Arn`.

### `!Sub`

String substitution — the one you'll use most for building ARNs/URLs. Two forms:

1. **Implicit** — references anything already in scope (parameters, resource logical
   IDs via `Ref`, `GetAtt` dotted paths, pseudo parameters):
   ```yaml
   Resource: !Sub "arn:aws:bedrock:*:${AWS::AccountId}:inference-profile/*"
   ```
2. **Explicit mapping** — pass a second argument to define/override variable names:
   ```yaml
   !Sub
     - "https://${Domain}/path"
     - Domain: !GetAtt MyApi.DomainName
   ```

`${AWS::AccountId}` and `${AWS::Region}` (used in this project's `Outputs.ApiEndpoint`)
are **pseudo parameters** — built-in values CloudFormation fills in at deploy time
(others: `AWS::StackName`, `AWS::Partition`, `AWS::NoValue`).

### `!Join`

Concatenates a list of values with a delimiter — the "manual" way to build a string
before `!Sub` existed:
```yaml
!Join ["", ["arn:aws:s3:::", !Ref DocumentBucket, "/*"]]
```
Equivalent to `!Sub "arn:aws:s3:::${DocumentBucket}/*"`. Prefer `!Sub` for readability;
reach for `!Join` mainly when the pieces are already a list you're building
programmatically (e.g. output of `!GetAZs`, `!Split`, or `Fn::If`).

## Where to learn it

1. **SAM template anatomy (start here)** —
   https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-specification-template-anatomy.html
2. **Full property reference for every `AWS::Serverless::*` resource** —
   https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-resource-function.html
   (swap `-function` for `-api`, `-httpapi`, `-statemachine`, etc.)
3. **Globals section spec** —
   https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-specification-template-anatomy-globals.html
4. **Policy Templates** (shorthand IAM like `S3ReadPolicy`) —
   https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-policy-templates.html
5. **Event source types** (`Api`, `S3`, `SQS`, `Schedule`, `EventBridgeRule`, …) —
   https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-property-function-eventsource.html
6. **`sam init` example templates** — running `sam init` locally and picking a
   runtime/quickstart gives real, working `template.yaml` files to read; this is how
   this project's Image-based structure originated.
7. **Editor support** — the AWS Toolkit extension for VS Code/JetBrains gives inline
   schema validation and autocomplete for `template.yaml`; `sam validate --lint` (uses
   cfn-lint under the hood) catches syntax/schema errors before deploying.
