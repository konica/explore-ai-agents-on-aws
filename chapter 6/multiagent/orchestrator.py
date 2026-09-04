"""
Finance Orchestrator — A2A agent that delegates to the Stock sub-agent.

Local:
    1. python stock_mcp_server.py
    2. python stock_a2a_agent.py
    3. python orchestrator.py

Deploy: agentcore configure -e orchestrator.py --protocol A2A
"""

import logging
import os
import uuid

import boto3
import httpx
import uvicorn
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from fastapi import FastAPI
from strands import Agent
from strands.multiagent.a2a import A2AServer
from strands_tools.a2a_client import A2AClientToolProvider
from a2a.types import AgentCapabilities, AgentCard, AgentSkill

logging.basicConfig(level=logging.INFO)

RUNTIME_URL = os.environ.get("AGENTCORE_RUNTIME_URL", "http://127.0.0.1:9000/")
STOCK_A2A_URL = os.environ.get("STOCK_A2A_URL", "http://127.0.0.1:9001")


class SigV4HttpxAuth(httpx.Auth):
    """Signs outbound requests with SigV4 so IAM-authorized AgentCore runtimes accept them."""

    def __init__(self, service: str = "bedrock-agentcore", region: str | None = None):
        session = boto3.Session()
        self.region = region or session.region_name or "us-east-1"
        self.credentials = session.get_credentials()
        self.service = service

    def auth_flow(self, request):
        aws_request = AWSRequest(
            method=request.method, url=str(request.url), data=request.content, headers=dict(request.headers)
        )
        SigV4Auth(self.credentials, self.service, self.region).add_auth(aws_request)
        request.headers.update(dict(aws_request.headers))
        yield request


# A2AAgent isn't a Strands tool on its own; A2AClientToolProvider exposes it as one.
_is_agentcore = "bedrock-agentcore" in STOCK_A2A_URL
_stock_httpx_args = None
if _is_agentcore:
    # AgentCore Runtime only routes the exact ".../invocations" path, so the standard
    # A2A discovery GET to ".../invocations/.well-known/agent-card.json" is rejected
    # (403). Skip HTTP discovery below and register the stock agent's card directly.
    # Calls also need SigV4 auth and a stable runtime session id (so a multi-request
    # exchange keeps routing to the same container).
    _stock_httpx_args = {
        "auth": SigV4HttpxAuth(),
        "headers": {"X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": str(uuid.uuid4())},
    }

stock_agent_provider = A2AClientToolProvider(
    known_agent_urls=[] if _is_agentcore else [STOCK_A2A_URL],
    httpx_client_args=_stock_httpx_args,
)

if _is_agentcore:
    stock_agent_provider._discovered_agents[STOCK_A2A_URL] = AgentCard(
        name="Stock Agent",
        description="Provides stock prices and financial information.",
        url=STOCK_A2A_URL,
        version="1.0.0",
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=["text"],
        default_output_modes=["text"],
        skills=[
            AgentSkill(
                id="stock_lookup",
                name="Stock Price Lookup",
                description="Get latest stock prices and financial info for any publicly traded company.",
                tags=["stocks", "finance", "prices", "market"],
            ),
        ],
    )

orchestrator = Agent(
    name="Finance Orchestrator",
    description="Provides financial advice by coordinating with the Stock agent.",
    system_prompt=(
        "You are a financial advisor assistant. When users ask about stocks, "
        "investments, or market conditions, use the stock agent to get current prices. "
        "Provide helpful analysis and context with the data."
    ),
    tools=stock_agent_provider.tools,
    callback_handler=None,
)

SKILLS = [
    AgentSkill(
        id="finance_advisor",
        name="Finance Advisor",
        description="Answers finance questions using real-time stock data.",
        tags=["finance", "stocks", "investing", "market"],
        examples=[
            "How are the FAANG stocks doing?",
            "Should I look at NVDA right now?",
            "Compare AAPL and MSFT prices",
        ],
    ),
]

a2a_server = A2AServer(
    agent=orchestrator,
    http_url=RUNTIME_URL,
    serve_at_root=True,
    skills=SKILLS,
    version="1.0.0",
    enable_a2a_compliant_streaming=True,
)

app = FastAPI()


@app.get("/ping")
def ping():
    return {"status": "healthy"}


app.mount("/", a2a_server.to_fastapi_app())

if __name__ == "__main__":
    print(f"Finance Orchestrator on http://0.0.0.0:9000 (Stock Agent: {STOCK_A2A_URL})")
    uvicorn.run(app, host="0.0.0.0", port=9000)
