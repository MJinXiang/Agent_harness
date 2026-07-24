from typing import override

from harbor.agents.installed.claude_code import ClaudeCode
from harbor.models.agent.name import AgentName


class GeneralAgent(ClaudeCode):
    @staticmethod
    @override
    def name() -> str:
        return AgentName.GENERAL_AGENT.value
