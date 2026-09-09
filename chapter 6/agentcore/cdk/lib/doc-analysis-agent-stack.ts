import * as path from 'path';
import { CfnOutput, Stack, StackProps } from 'aws-cdk-lib';
import {
  AgentRuntimeArtifact,
  ProtocolType,
  Runtime,
  RuntimeNetworkConfiguration,
} from 'aws-cdk-lib/aws-bedrockagentcore';
import { Platform } from 'aws-cdk-lib/aws-ecr-assets';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

/**
 * Deploys the chapter 6 doc_analysis_agent (Strands + BedrockAgentCoreApp)
 * to Bedrock AgentCore Runtime, replacing the manual
 * bedrock_agentcore_starter_toolkit configure()/launch() flow from
 * agentcore_runtime_deploy.ipynb with a single reviewable stack.
 */
export class DocAnalysisAgentStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    // Builds the Docker image from ../ (the directory with the Dockerfile,
    // agent.py, requirements.txt) and publishes it as a CDK asset in ECR.
    // No CodeBuild project required: the CDK CLI builds it locally (with
    // buildx cross-platform emulation if needed) at `cdk deploy` time.
    const agentRuntimeArtifact = AgentRuntimeArtifact.fromAsset(
      path.join(__dirname, '..', '..'),
      { platform: Platform.LINUX_ARM64 }, // AgentCore Runtime requires ARM64
    );

    const runtime = new Runtime(this, 'DocAnalysisAgentRuntime', {
      runtimeName: 'doc_analysis_agent',
      description: 'Chapter 6 document analysis agent (Strands + Claude Sonnet 4.5)',
      agentRuntimeArtifact,
      protocolConfiguration: ProtocolType.HTTP,
      networkConfiguration: RuntimeNetworkConfiguration.usingPublicNetwork(),
      tracingEnabled: true,
      // executionRole omitted: Runtime auto-creates one scoped to this
      // runtime's own ECR pull / CloudWatch Logs / X-Ray permissions.
    });

    // The auto-created execution role does NOT include bedrock:InvokeModel
    // (that's the agent's own model call, not "runtime infra" access) --
    // grant it explicitly for the Claude Sonnet 4.5 model agent.py invokes.
    runtime.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
        resources: [
          `arn:aws:bedrock:${this.region}::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0`,
          `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0`,
        ],
      }),
    );

    // A DEFAULT endpoint is created automatically alongside the runtime by
    // the AgentCore service itself (same one the starter toolkit invoked
    // with qualifier="DEFAULT") -- no separate RuntimeEndpoint needed here.
    // Use runtime.addEndpoint('stable') to pin a named endpoint to a
    // specific runtime version for blue/green-style rollouts instead.

    new CfnOutput(this, 'AgentRuntimeArn', { value: runtime.agentRuntimeArn });
    new CfnOutput(this, 'AgentRuntimeId', { value: runtime.agentRuntimeId });
  }
}
