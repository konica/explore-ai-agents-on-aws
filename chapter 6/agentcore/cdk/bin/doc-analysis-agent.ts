#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { DocAnalysisAgentStack } from '../lib/doc-analysis-agent-stack';

const app = new cdk.App();

new DocAnalysisAgentStack(app, 'DocAnalysisAgentStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
