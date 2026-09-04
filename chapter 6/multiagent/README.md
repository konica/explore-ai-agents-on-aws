# Multi-Agent Finance Example: MCP + A2A on Amazon Bedrock AgentCore

A multi-agent finance system: one MCP server for stock price tools, one A2A sub-agent with web search, one A2A orchestrator.

## Architecture

```
    ┌──────────────────┐
    │    Finance       │
    │  Orchestrator    │
    │  (A2A :9000)     │
    └────────┬─────────┘
             │ A2A
             ▼
    ┌──────────────────┐
    │   Stock Agent    │
    │  (A2A :9001)     │
    │  + web search    │
    └───┬──────────────┘
        │ MCP
        ▼
    ┌──────────────────┐
    │   Stock Tools    │
    │  (MCP :8000)     │
    │  yfinance prices │
    └──────────────────┘
```

- MCP Server uses yfinance to fetch real stock prices
- Stock A2A Agent connects to MCP for prices + uses Strands `http_request` for web data
- Orchestrator delegates finance questions to the Stock Agent via A2A

## Files

| File | Protocol | Port | Description |
|---|---|---|---|
| `stock_mcp_server.py` | MCP | 8000 | Stock price tools (yfinance) |
| `stock_a2a_agent.py` | A2A | 9001 local / **9000 on AgentCore** (`PORT` env var) | Sub-agent with MCP tools + web search |
| `orchestrator.py` | A2A | 9000 | Main agent delegating to stock agent |

AgentCore requires every A2A-protocol container to listen on port 9000, so `stock_a2a_agent.py`
reads its port from the `PORT` env var (default `9001`, used only so it can run locally alongside
`orchestrator.py` without a port clash — see [Deploy Stock A2A Agent](#step-4-deploy-stock-a2a-agent)).

## Local Testing

```bash
pip install -r requirements.txt

# Terminal 1: Start MCP server
python stock_mcp_server.py

# Terminal 2: Start Stock A2A agent
python stock_a2a_agent.py

# Terminal 3: Start Orchestrator (or test stock agent directly via curl)
python orchestrator.py
```

Test the stock agent directly:
```bash
curl -X POST http://localhost:9001/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0", "id": "1", "method": "message/send",
    "params": {"message": {"role": "user",
      "parts": [{"kind": "text", "text": "What is the current price of AAPL?"}],
      "messageId": "test-1"}}
  }' | jq .
```

## Deploy to AgentCore

### Step 1: Install tools

```bash
pip install -r requirements.txt
pip install bedrock-agentcore-starter-toolkit
```

### Step 2: Set up Cognito auth

```bash
export REGION=us-east-1
export USERNAME=testuser
export PASSWORD='AgentCore123!'

POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "FinanceAgentPool" \
  --policies '{"PasswordPolicy":{"MinimumLength":8}}' \
  --region $REGION --query "UserPool.Id" --output text)

CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id $POOL_ID --client-name "FinanceClient" \
  --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region $REGION --query "UserPoolClient.ClientId" --output text)

aws cognito-idp admin-create-user \
  --user-pool-id $POOL_ID --username $USERNAME \
  --region $REGION --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id $POOL_ID --username $USERNAME \
  --password $PASSWORD --region $REGION --permanent

BEARER_TOKEN=$(aws cognito-idp initiate-auth \
  --client-id $CLIENT_ID --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" \
  --region $REGION --query "AuthenticationResult.AccessToken" --output text)

echo "Discovery URL: https://cognito-idp.$REGION.amazonaws.com/$POOL_ID/.well-known/openid-configuration"
echo "Client ID: $CLIENT_ID"
echo "Bearer Token: $BEARER_TOKEN"
```

### Step 3: Deploy MCP Server

```bash
agentcore configure -e stock_mcp_server.py --protocol MCP --non-interactive
agentcore launch
```

Build the MCP invoke URL. AgentCore's data-plane endpoint for **any** protocol is always
`/runtimes/{arn}/invocations?qualifier=DEFAULT` — do **not** append `/mcp` (that path only exists
inside the container; a client-facing URL that includes it gets a 404/`UnknownOperationException`
from the AgentCore gateway itself, before your code ever runs):
```bash
MCP_ARN_ENCODED=$(echo -n "<mcp-runtime-arn>" | jq -sRr '@uri')
export STOCK_MCP_URL="https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$MCP_ARN_ENCODED/invocations?qualifier=DEFAULT"
```

### Step 4: Deploy Stock A2A Agent

`agentcore launch` does not read your shell's environment into the container — pass values the
code needs with `--env`. AgentCore also requires every A2A container to listen on **port 9000**
(see the generated Dockerfile's `EXPOSE 9000`); `stock_a2a_agent.py` defaults to 9001 locally
(so it can run alongside `orchestrator.py` on one machine) and needs `PORT=9000` at deploy time:

```bash
agentcore configure -e stock_a2a_agent.py --protocol A2A --non-interactive
agentcore launch --env "STOCK_MCP_URL=$STOCK_MCP_URL" --env "PORT=9000"
```

Grant this agent's execution role permission to invoke the MCP server's runtime — AgentCore
auto-creates each execution role scoped to invoke only *itself*, so cross-agent calls 403 until
you add this explicitly (find the role name in `.bedrock_agentcore.yaml` under
`stock_a2a_agent.aws.execution_role`):

```bash
aws iam put-role-policy --role-name <stock_a2a_agent-execution-role-name> \
  --policy-name CrossAgentInvokeMcpServer \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock-agentcore:InvokeAgentRuntime","bedrock-agentcore:InvokeAgentRuntimeForUser"],"Resource":["arn:aws:bedrock-agentcore:'"$REGION"':<account-id>:runtime/stock_mcp_server-*"]}]}'
```

Build the Stock Agent's invoke URL the same way (no protocol-specific suffix, just `?qualifier=DEFAULT`):
```bash
A2A_ARN_ENCODED=$(echo -n "<stock-a2a-runtime-arn>" | jq -sRr '@uri')
export STOCK_A2A_URL="https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$A2A_ARN_ENCODED/invocations?qualifier=DEFAULT"
```

### Step 5: Deploy Orchestrator

The orchestrator is the externally-facing agent, so it needs the Cognito OAuth authorizer from
Step 2 (internal agent-to-agent calls use SigV4/IAM instead — see `orchestrator.py` and
`stock_a2a_agent.py` for the `SigV4HttpxAuth` helper used for those):

```bash
agentcore configure -e orchestrator.py --protocol A2A --non-interactive \
  --authorizer-config "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"https://cognito-idp.$REGION.amazonaws.com/$POOL_ID/.well-known/openid-configuration\",\"allowedClients\":[\"$CLIENT_ID\"]}}"
agentcore launch --env "STOCK_A2A_URL=$STOCK_A2A_URL"
```

Grant the orchestrator's execution role permission to invoke the Stock Agent's runtime, same as Step 4:

```bash
aws iam put-role-policy --role-name <orchestrator-execution-role-name> \
  --policy-name CrossAgentInvokeStockAgent \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock-agentcore:InvokeAgentRuntime","bedrock-agentcore:InvokeAgentRuntimeForUser"],"Resource":["arn:aws:bedrock-agentcore:'"$REGION"':<account-id>:runtime/stock_a2a_agent-*"]}]}'
```

### Step 6: Test

`BEARER_TOKEN` from Step 2 expires after ~1 hour — re-run the `initiate-auth` call to mint a fresh
one if you get `"Token has expired"`.

```bash
ORCH_ARN_ENCODED=$(echo -n "<orchestrator-runtime-arn>" | jq -sRr '@uri')

curl -X POST "https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$ORCH_ARN_ENCODED/invocations?qualifier=DEFAULT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $BEARER_TOKEN" \
  -d '{
    "jsonrpc": "2.0", "id": "1", "method": "message/send",
    "params": {"message": {"role": "user",
      "parts": [{"kind": "text", "text": "How is NVDA stock doing today?"}],
      "messageId": "test-1"}}
  }' | jq .
```

The first call to a freshly deployed/updated agent pays a cold-start cost (the container imports
Strands/boto3/mcp and connects to its downstream agent before it can serve requests) and can take
30-100s; a warm container responds in a few seconds.
