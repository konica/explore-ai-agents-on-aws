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
