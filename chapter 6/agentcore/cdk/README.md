# doc_analysis_agent — CDK stack

Manages `doc_analysis_agent`'s AgentCore Runtime, ECR image, and execution role as one
CloudFormation stack, using the `aws-bedrockagentcore` module in `aws-cdk-lib` (>= 2.268.0)
instead of `bedrock_agentcore_starter_toolkit.Runtime.configure()/launch()` from
`agentcore_runtime_deploy.ipynb`.

## What it creates

- `AWS::BedrockAgentCore::Runtime` (`doc_analysis_agent`) — built from the `Dockerfile` in the
  parent `chapter 6/agentcore` directory as a CDK Docker image asset (`AgentRuntimeArtifact.fromAsset`),
  published to the CDK bootstrap ECR repo and forced to `linux/arm64` as AgentCore requires.
- An auto-created IAM execution role, scoped by the L2 `Runtime` construct to this runtime's own
  ECR pull / CloudWatch Logs / X-Ray permissions, plus an explicit `bedrock:InvokeModel` /
  `InvokeModelWithResponseStream` grant for the Claude Sonnet 4.5 model `agent.py` calls.
- The `DEFAULT` runtime endpoint (created automatically by the AgentCore service alongside the
  runtime — no separate `RuntimeEndpoint` resource needed for the common case).

## Prerequisites

- Node.js 18+, Docker running locally (the asset build needs `buildx` for the ARM64 cross-build
  if you're on an x86 machine — same constraint the notebook hit).
- `cdk bootstrap` run once per account/region if you haven't already.

## Usage

```bash
npm install
npx cdk bootstrap   # first time only, per account/region
npx cdk diff         # see what would change
npx cdk deploy       # build the image, push it, create/update the stack
npx cdk destroy      # tear everything down in one step
```

`cdk deploy` prints `AgentRuntimeArn` and `AgentRuntimeId` as stack outputs — use them the same
way the notebook used `launch_result.agent_arn` / `.agent_id` with `boto3`'s
`bedrock-agentcore` `invoke_agent_runtime`.

## Why this instead of the starter toolkit

- One `cdk destroy` removes the runtime, its execution role, and the published image asset —
  no local `.bedrock_agentcore.yaml` state file to fall out of sync with reality (see the
  `doc_analysis_agent` cleanup earlier in this chapter's history, where the toolkit's config had
  drifted and `agentcore destroy` would have skipped the still-running runtime).
- Changes go through `cdk diff`/a stack update instead of imperative boto3 calls, so they're
  reviewable and reproducible in CI.
- `cdk deploy` still needs Docker locally for the image build — it does not add a CodeBuild
  project the way the starter toolkit's remote cross-platform build does. If you'd rather build
  in CI/CodeBuild, use `AgentRuntimeArtifact.fromEcrRepository(repo, tag)` instead and push the
  image yourself as a separate pipeline step.
