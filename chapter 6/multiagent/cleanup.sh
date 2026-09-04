#!/bin/bash
# Tears down the AWS resources created by deploying this example to Bedrock AgentCore
# (see README.md "Deploy to AgentCore"): the 3 agent runtimes and everything
# `agentcore configure`/`launch` created for them, plus the things it deliberately
# leaves behind (memory resources, the extra cross-agent IAM grants) and the
# Cognito user pool from Step 2.
#
# Usage:
#   ./cleanup.sh              # asks for confirmation, then deletes everything
#   ./cleanup.sh --dry-run    # prints what would be deleted, changes nothing
#   ./cleanup.sh --yes        # skips the confirmation prompt
#
# Run from anywhere; it locates its own directory. Requires the `agentcore` CLI
# (bedrock-agentcore-starter-toolkit) and `aws` CLI configured for this account.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${REGION:-us-east-1}"
AGENTS=(orchestrator stock_a2a_agent stock_mcp_server)

# Cognito resources from README Step 2. Override if you used different values.
COGNITO_POOL_ID="${COGNITO_POOL_ID:-us-east-1_9hRe6XI6m}"

DRY_RUN=false
SKIP_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) SKIP_CONFIRM=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Locate the agentcore CLI: prefer PATH, fall back to the venv this project used.
AGENTCORE_BIN="agentcore"
if ! command -v agentcore >/dev/null 2>&1; then
  if [ -x "$HOME/.venvs/ch6-multiagent/bin/agentcore" ]; then
    AGENTCORE_BIN="$HOME/.venvs/ch6-multiagent/bin/agentcore"
  else
    echo "error: 'agentcore' CLI not found. Install with:" >&2
    echo "  pip install bedrock-agentcore-starter-toolkit" >&2
    exit 1
  fi
fi
export AGENTCORE_SUPPRESS_RECOMMENDATION=1

run() {
  echo "+ $*"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  "$@"
}

echo "=== Multi-agent finance example: AWS teardown ==="
echo "Region: $REGION"
echo "Agents: ${AGENTS[*]}"
echo "Cognito pool: $COGNITO_POOL_ID"
[ "$DRY_RUN" = true ] && echo "(dry run — nothing will actually be deleted)"
echo ""
echo "This does NOT touch chapter 6/agentcore's doc_analysis_agent or any other"
echo "deployed agent outside this example."
echo ""

if [ "$DRY_RUN" = false ] && [ "$SKIP_CONFIRM" = false ]; then
  read -r -p "Delete these AWS resources? This cannot be undone. [y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

cd "$SCRIPT_DIR"

# --- Step 1: remove the hand-added cross-agent IAM grants -------------------
# agentcore destroy only deletes execution roles it fully manages; roles carrying
# an extra inline policy it didn't create (like these) can otherwise fail to delete.
echo ""
echo "--- Removing cross-agent IAM grants ---"
if [ -f .bedrock_agentcore.yaml ]; then
  ORCH_ROLE=$(python3 - <<'PY'
import yaml
try:
    with open(".bedrock_agentcore.yaml") as f:
        d = yaml.safe_load(f)
    agents = d.get("agents", {})
    orch = agents.get("orchestrator", {}).get("aws", {}).get("execution_role", "")
    stock = agents.get("stock_a2a_agent", {}).get("aws", {}).get("execution_role", "")
    print(orch.rsplit("/", 1)[-1] if orch else "")
    print(stock.rsplit("/", 1)[-1] if stock else "")
except FileNotFoundError:
    print("")
    print("")
PY
)
  ORCH_ROLE_NAME=$(echo "$ORCH_ROLE" | sed -n '1p')
  STOCK_ROLE_NAME=$(echo "$ORCH_ROLE" | sed -n '2p')

  if [ -n "$ORCH_ROLE_NAME" ]; then
    run aws iam delete-role-policy --role-name "$ORCH_ROLE_NAME" --policy-name CrossAgentInvokeStockAgent \
      || echo "  (already gone or role missing — continuing)"
  fi
  if [ -n "$STOCK_ROLE_NAME" ]; then
    run aws iam delete-role-policy --role-name "$STOCK_ROLE_NAME" --policy-name CrossAgentInvokeMcpServer \
      || echo "  (already gone or role missing — continuing)"
  fi
else
  echo "  .bedrock_agentcore.yaml not found — skipping (already cleaned up?)"
fi

# --- Step 2: delete memory resources -----------------------------------------
# agentcore destroy preserves memory by default (it doesn't know if you want the
# conversation history), so it needs deleting explicitly.
echo ""
echo "--- Deleting memory resources ---"
if [ -f .bedrock_agentcore.yaml ]; then
  MEMORY_IDS=$(python3 - <<'PY'
import yaml
try:
    with open(".bedrock_agentcore.yaml") as f:
        d = yaml.safe_load(f)
    for name, cfg in d.get("agents", {}).items():
        mem_id = cfg.get("memory", {}).get("memory_id")
        if mem_id:
            print(mem_id)
except FileNotFoundError:
    pass
PY
)
  while IFS= read -r mem_id; do
    [ -z "$mem_id" ] && continue
    run "$AGENTCORE_BIN" memory delete "$mem_id" --region "$REGION" --wait \
      || echo "  (already gone — continuing)"
  done <<< "$MEMORY_IDS"
else
  echo "  .bedrock_agentcore.yaml not found — skipping"
fi

# --- Step 3: destroy each agent runtime --------------------------------------
# Removes: the runtime, its ECR images + repo, its CodeBuild project + role,
# its runtime execution role, and its S3 build artifacts.
echo ""
echo "--- Destroying agent runtimes ---"
for agent in "${AGENTS[@]}"; do
  echo ""
  echo "  agent: $agent"
  DESTROY_FLAGS=(--agent "$agent" --delete-ecr-repo)
  [ "$DRY_RUN" = true ] && DESTROY_FLAGS+=(--dry-run) || DESTROY_FLAGS+=(--force)
  # agentcore's own --dry-run is non-destructive, so run it directly (not via the
  # `run` wrapper) even in dry-run mode — it's the source of the detailed preview.
  echo "+ $AGENTCORE_BIN destroy ${DESTROY_FLAGS[*]}"
  "$AGENTCORE_BIN" destroy "${DESTROY_FLAGS[@]}" \
    || echo "  destroy reported an issue for $agent — check output above"
done

# --- Step 4: delete the Cognito user pool ------------------------------------
# Deleting the pool cascades: its app client (FinanceClient) and users (testuser)
# go with it, no separate calls needed.
echo ""
echo "--- Deleting Cognito user pool ---"
run aws cognito-idp delete-user-pool --user-pool-id "$COGNITO_POOL_ID" --region "$REGION" \
  || echo "  (already gone — continuing)"

echo ""
echo "=== Teardown complete ==="
echo "Local files (.bedrock_agentcore.yaml, .bedrock_agentcore/, Dockerfile,"
echo ".dockerignore, __pycache__) were left in place — remove them by hand if"
echo "you want a clean checkout; they now reference deleted resources."
