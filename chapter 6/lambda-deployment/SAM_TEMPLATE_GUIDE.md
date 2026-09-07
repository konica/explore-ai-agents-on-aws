# Writing `template.yaml` for AWS SAM

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
