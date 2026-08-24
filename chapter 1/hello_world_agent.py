"""Chapter 1: Hello World Agent using Strands Agents SDK."""

from strands import Agent
from strands.models.bedrock import BedrockModel

# Use Nova Lite — always available, no approval expiry
# To use Claude instead: BedrockModel(model_id="us.anthropic.claude-haiku-4-5-20251001-v1:0")
model = BedrockModel(model_id="us.anthropic.claude-haiku-4-5-20251001-v1:0")

agent = Agent(model=model)

response = agent("Hello! Tell me a fun fact about AI agents.")
print(response)
