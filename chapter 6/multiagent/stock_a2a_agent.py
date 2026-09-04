"""
Stock A2A Agent — uses Strands web search tool + MCP stock tools.

Combines web search (for news/analysis) with MCP stock price lookup
to answer finance questions.

Local:
    1. python stock_mcp_server.py
    2. python stock_a2a_agent.py

Deploy: agentcore configure -e stock_a2a_agent.py --protocol A2A
"""

import logging
import os

import boto3
import httpx
import uvicorn
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from fastapi import FastAPI
from strands import Agent
from strands.tools.mcp import MCPClient
from strands_tools import http_request
from mcp.client.streamable_http import streamablehttp_client
from strands.multiagent.a2a import A2AServer
from a2a.types import AgentSkill

logging.basicConfig(level=logging.INFO)

STOCK_MCP_URL = os.environ.get("STOCK_MCP_URL", "http://localhost:8000/mcp")
RUNTIME_URL = os.environ.get("AGENTCORE_RUNTIME_URL", "http://127.0.0.1:9001/")
# AgentCore Runtime requires A2A containers to listen on port 9000 (see the generated
# Dockerfile's EXPOSE). Locally we default to 9001 so this can run alongside orchestrator.py
# (which uses 9000) on one machine; deploys must pass --env PORT=9000.
PORT = int(os.environ.get("PORT", "9001"))


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


# MCP client for stock price tools. AgentCore MCP runtimes require SigV4 auth. terminate_on_close
# must be False: the default sends a session-close DELETE that tears down the AgentCore session
# before the client is done using it, breaking later tool calls.
_mcp_auth = SigV4HttpxAuth() if "bedrock-agentcore" in STOCK_MCP_URL else None
mcp_client = MCPClient(
    lambda: streamablehttp_client(STOCK_MCP_URL, auth=_mcp_auth, timeout=120, terminate_on_close=False)
)

stock_agent = Agent(
    name="Stock Agent",
    description="Provides stock prices and financial information.",
    system_prompt=(
        "You are a financial assistant. Use get_stock_price to look up current stock prices. "
        "Use http_request to fetch data from financial websites when needed. "
        "Always provide the ticker symbol, current price, and any relevant context."
    ),
    tools=[mcp_client, http_request],
    callback_handler=None,
)

SKILLS = [
    AgentSkill(
        id="stock_lookup",
        name="Stock Price Lookup",
        description="Get latest stock prices and financial info for any publicly traded company.",
        tags=["stocks", "finance", "prices", "market"],
        examples=[
            "What is the current price of AAPL?",
            "How is AMZN doing today?",
            "Get me the stock price for MSFT and GOOGL",
        ],
    ),
]

a2a_server = A2AServer(
    agent=stock_agent,
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
    print(f"Stock A2A Agent on http://0.0.0.0:{PORT} (MCP: {STOCK_MCP_URL})")
    uvicorn.run(app, host="0.0.0.0", port=PORT)
