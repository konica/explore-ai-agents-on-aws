#!/bin/bash
# Deploys the multi-agent finance example to Bedrock AgentCore end-to-end
# (see README.md "Deploy to AgentCore" for the manual, step-by-step version
# this automates): Cognito auth, all 3 runtimes in dependency order, and the
# cross-agent IAM grants AgentCore doesn't set up on its own.
#
# Usage: ./deploy.sh
#
# Safe to re-run: reuses an existing Cognito pool/client by name, and
# redeploys agents in place (--auto-update-on-conflict) rather than failing
# on "already exists".
#
# Run from anywhere; it locates its own directory. Requires the `agentcore`
# CLI (bedrock-agentcore-starter-toolkit), `aws`, `jq`, and `python3` (with
# PyYAML) on PATH, and AWS credentials configured for this account.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${REGION:-us-east-1}"
USERNAME="${COGNITO_USERNAME:-testuser}"
PASSWORD="${COGNITO_PASSWORD:-AgentCore123!}"
POOL_NAME="FinanceAgentPool"
CLIENT_NAME="FinanceClient"

# Locate the agentcore CLI: prefer PATH, fall back to the venv this project used.
AGENTCORE_BIN="agentcore"
if ! command -v agentcore >/dev/null 2>&1; then
  if [ -x "$HOME/.venvs/ch6-multiagent/bin/agentcore" ]; then
    AGENTCORE_BIN="$HOME/.venvs/ch6-multiagent/bin/agentcore"
  else
    echo "error: 'agentcore' CLI not found. Install with:" >&2
    echo "  pip install -r requirements.txt && pip install bedrock-agentcore-starter-toolkit" >&2
    exit 1
  fi
fi
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

for bin in aws jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required but not found on PATH." >&2; exit 1; }
done
python3 -c "import yaml" 2>/dev/null || { echo "error: PyYAML is required (pip install pyyaml)." >&2; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "error: AWS credentials not configured. Run 'aws configure' first." >&2
  exit 1
}

must() {
  echo "+ $*"
  "$@" || { echo "error: command failed: $*" >&2; exit 1; }
}

# Reads a dotted field (e.g. "bedrock_agentcore.agent_arn") for one agent out of
# .bedrock_agentcore.yaml, written by the agentcore CLI after configure/launch.
yaml_get() {
  local agent="$1" path="$2"
  python3 - "$agent" "$path" <<'PY'
import sys, yaml
agent, path = sys.argv[1], sys.argv[2]
with open(".bedrock_agentcore.yaml") as f:
    d = yaml.safe_load(f)
node = d["agents"][agent]
for key in path.split("."):
    node = node[key]
print(node)
PY
}

encode_arn() {
  printf '%s' "$1" | jq -sRr '@uri'
}

invoke_url() {
  # AgentCore's client-facing endpoint is always .../invocations?qualifier=DEFAULT
  # for every protocol -- MCP's /mcp path only exists inside the container.
  local arn_encoded
  arn_encoded=$(encode_arn "$1")
  echo "https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$arn_encoded/invocations?qualifier=DEFAULT"
}

grant_invoke() {
  # Grants $1's execution role permission to invoke runtimes matching $2-*.
  # AgentCore auto-creates each execution role scoped to invoke only itself,
  # so agent-to-agent calls (A2A delegation, MCP tool calls) 403 without this.
  local agent="$1" target_prefix="$2" policy_name="$3"
  local role_arn role_name
  role_arn=$(yaml_get "$agent" "aws.execution_role")
  role_name="${role_arn##*/}"
  must aws iam put-role-policy --role-name "$role_name" --policy-name "$policy_name" \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:InvokeAgentRuntime\",\"bedrock-agentcore:InvokeAgentRuntimeForUser\"],\"Resource\":[\"arn:aws:bedrock-agentcore:$REGION:$ACCOUNT_ID:runtime/$target_prefix-*\"]}]}"
}

echo "=== Multi-agent finance example: AgentCore deploy ==="
echo "  Account: $ACCOUNT_ID"
echo "  Region:  $REGION"
echo ""

cd "$SCRIPT_DIR"

# --- Step 1: Cognito auth (idempotent: reuses an existing pool/client by name) ---
echo "--- Step 1: Cognito auth ---"
POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$REGION" \
  --query "UserPools[?Name=='$POOL_NAME'].Id | [0]" --output text)
if [ "$POOL_ID" = "None" ] || [ -z "$POOL_ID" ]; then
  echo "Creating Cognito user pool '$POOL_NAME'..."
  POOL_ID=$(aws cognito-idp create-user-pool --pool-name "$POOL_NAME" \
    --policies '{"PasswordPolicy":{"MinimumLength":8}}' \
    --region "$REGION" --query "UserPool.Id" --output text)
else
  echo "Reusing existing user pool: $POOL_ID"
fi

CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --region "$REGION" \
  --query "UserPoolClients[?ClientName=='$CLIENT_NAME'].ClientId | [0]" --output text)
if [ "$CLIENT_ID" = "None" ] || [ -z "$CLIENT_ID" ]; then
  echo "Creating app client '$CLIENT_NAME'..."
  CLIENT_ID=$(aws cognito-idp create-user-pool-client --user-pool-id "$POOL_ID" \
    --client-name "$CLIENT_NAME" --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --region "$REGION" --query "UserPoolClient.ClientId" --output text)
else
  echo "Reusing existing app client: $CLIENT_ID"
fi

aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username "$USERNAME" \
  --region "$REGION" --message-action SUPPRESS >/dev/null 2>&1 || true
must aws cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" --username "$USERNAME" \
  --password "$PASSWORD" --region "$REGION" --permanent

DISCOVERY_URL="https://cognito-idp.$REGION.amazonaws.com/$POOL_ID/.well-known/openid-configuration"
echo "  Pool:   $POOL_ID"
echo "  Client: $CLIENT_ID"

# --- Step 2: Deploy MCP Server -----------------------------------------------
echo ""
echo "--- Step 2: Deploy Stock MCP Server (this triggers a ~1min CodeBuild build) ---"
must "$AGENTCORE_BIN" configure -e stock_mcp_server.py --protocol MCP --non-interactive
must "$AGENTCORE_BIN" launch --auto-update-on-conflict

MCP_ARN=$(yaml_get stock_mcp_server "bedrock_agentcore.agent_arn")
STOCK_MCP_URL=$(invoke_url "$MCP_ARN")
echo "  ARN: $MCP_ARN"

# --- Step 3: Deploy Stock A2A Agent ------------------------------------------
# AgentCore requires A2A containers to listen on port 9000 (see the generated
# Dockerfile's EXPOSE); stock_a2a_agent.py defaults to 9001 locally to avoid
# clashing with orchestrator.py on one machine, so PORT=9000 is required here.
echo ""
echo "--- Step 3: Deploy Stock A2A Agent ---"
must "$AGENTCORE_BIN" configure -e stock_a2a_agent.py --protocol A2A --non-interactive
must "$AGENTCORE_BIN" launch --auto-update-on-conflict \
  --env "STOCK_MCP_URL=$STOCK_MCP_URL" --env "PORT=9000"

STOCK_A2A_ARN=$(yaml_get stock_a2a_agent "bedrock_agentcore.agent_arn")
STOCK_A2A_URL=$(invoke_url "$STOCK_A2A_ARN")
echo "  ARN: $STOCK_A2A_ARN"

echo "  Granting stock_a2a_agent's role permission to invoke stock_mcp_server..."
grant_invoke stock_a2a_agent stock_mcp_server CrossAgentInvokeMcpServer

# --- Step 4: Deploy Orchestrator ---------------------------------------------
# The orchestrator is externally-facing, so it authenticates callers via the
# Cognito pool from Step 1 (agent-to-agent calls below use SigV4/IAM instead).
echo ""
echo "--- Step 4: Deploy Orchestrator ---"
AUTHORIZER_CONFIG="{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$DISCOVERY_URL\",\"allowedClients\":[\"$CLIENT_ID\"]}}"
must "$AGENTCORE_BIN" configure -e orchestrator.py --protocol A2A --non-interactive \
  --authorizer-config "$AUTHORIZER_CONFIG"
must "$AGENTCORE_BIN" launch --auto-update-on-conflict --env "STOCK_A2A_URL=$STOCK_A2A_URL"

ORCH_ARN=$(yaml_get orchestrator "bedrock_agentcore.agent_arn")
echo "  ARN: $ORCH_ARN"

echo "  Granting orchestrator's role permission to invoke stock_a2a_agent..."
grant_invoke orchestrator stock_a2a_agent CrossAgentInvokeStockAgent

# --- Done ---------------------------------------------------------------------
echo ""
echo "Waiting 10s for the IAM grants to propagate..."
sleep 10

BEARER_TOKEN=$(aws cognito-idp initiate-auth --client-id "$CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" --region "$REGION" \
  --query "AuthenticationResult.AccessToken" --output text)
ORCH_URL=$(invoke_url "$ORCH_ARN")

echo ""
echo "=== Deployment complete ==="
echo "  stock_mcp_server: $MCP_ARN"
echo "  stock_a2a_agent:  $STOCK_A2A_ARN"
echo "  orchestrator:     $ORCH_ARN"
echo ""
echo "Test it (the bearer token above is fresh but expires in ~1 hour):"
echo "  curl -X POST \"$ORCH_URL\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -H \"Authorization: Bearer $BEARER_TOKEN\" \\"
echo "    -d '{\"jsonrpc\": \"2.0\", \"id\": \"1\", \"method\": \"message/send\", \"params\": {\"message\": {\"role\": \"user\", \"parts\": [{\"kind\": \"text\", \"text\": \"How is NVDA stock doing today?\"}], \"messageId\": \"test-1\"}}}' | jq ."
echo ""
echo "The first call to a freshly deployed agent pays a cold-start cost (30-100s);"
echo "a warm container responds in a few seconds. Run ./cleanup.sh to tear this down."
