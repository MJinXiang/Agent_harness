import json
from unittest.mock import AsyncMock

import pytest

from harbor.agents.factory import AgentFactory
from harbor.agents.installed.claude_code import ClaudeCode
from harbor.agents.installed.general_agent import GeneralAgent
from harbor.models.agent.name import AgentName
from harbor.models.trial.config import AgentConfig


def _write_session(logs_dir):
    session_dir = logs_dir / "projects" / "test-project" / "test-session"
    session_dir.mkdir(parents=True)
    event = {
        "type": "assistant",
        "timestamp": "2026-01-01T00:00:00Z",
        "sessionId": "test-session",
        "version": "2.1.50",
        "message": {
            "id": "msg_1",
            "model": "claude-opus-4-8",
            "role": "assistant",
            "content": [{"type": "text", "text": "Done."}],
            "usage": {"input_tokens": 10, "output_tokens": 5},
        },
    }
    (session_dir / "session.jsonl").write_text(json.dumps(event) + "\n")
    return session_dir


def _mock_environment():
    environment = AsyncMock()
    environment.default_user = "agent"
    environment.exec.return_value = AsyncMock(return_code=0, stdout="", stderr="")
    return environment


def test_factory_creates_general_agent_and_preserves_legacy_entry(tmp_path):
    general = AgentFactory.create_agent_from_config(
        AgentConfig(name="general_agent", model_name="anthropic/claude-opus-4-8"),
        logs_dir=tmp_path,
    )
    legacy = AgentFactory.create_agent_from_config(
        AgentConfig(name="claude-code", model_name="anthropic/claude-opus-4-8"),
        logs_dir=tmp_path,
    )

    assert AgentName.GENERAL_AGENT.value in AgentName.values()
    assert isinstance(general, GeneralAgent)
    assert isinstance(general, ClaudeCode)
    assert general.name() == "general_agent"
    assert general.to_agent_info().name == "general_agent"
    assert type(legacy) is ClaudeCode
    assert legacy.name() == "claude-code"
    assert legacy.to_agent_info().name == "claude-code"


def test_trajectory_uses_public_agent_identity(tmp_path):
    session_dir = _write_session(tmp_path)
    general = GeneralAgent(logs_dir=tmp_path)
    legacy = ClaudeCode(logs_dir=tmp_path)

    general_trajectory = general._convert_events_to_trajectory(session_dir)
    legacy_trajectory = legacy._convert_events_to_trajectory(session_dir)

    if general_trajectory is None or legacy_trajectory is None:
        raise RuntimeError("Expected both agent trajectories to be generated")
    assert general_trajectory.agent.name == "general_agent"
    assert legacy_trajectory.agent.name == "claude-code"


def test_cost_parser_reads_identity_specific_log(tmp_path):
    (tmp_path / "general_agent.txt").write_text(
        json.dumps({"type": "result", "total_cost_usd": 1.25}) + "\n"
    )
    (tmp_path / "claude-code.txt").write_text(
        json.dumps({"type": "result", "total_cost_usd": 2.5}) + "\n"
    )

    assert GeneralAgent(logs_dir=tmp_path)._parse_total_cost_from_stream_json() == 1.25
    assert ClaudeCode(logs_dir=tmp_path)._parse_total_cost_from_stream_json() == 2.5


@pytest.mark.asyncio
async def test_run_writes_identity_specific_log(tmp_path, monkeypatch):
    for name in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_FORCE_OAUTH",
    ):
        monkeypatch.delenv(name, raising=False)

    general_environment = _mock_environment()
    legacy_environment = _mock_environment()

    await GeneralAgent(logs_dir=tmp_path).run(
        "do something", general_environment, AsyncMock()
    )
    await ClaudeCode(logs_dir=tmp_path).run(
        "do something", legacy_environment, AsyncMock()
    )

    general_command = general_environment.exec.call_args_list[-1].kwargs["command"]
    legacy_command = legacy_environment.exec.call_args_list[-1].kwargs["command"]
    assert "tee /logs/agent/general_agent.txt" in general_command
    assert "tee /logs/agent/claude-code.txt" in legacy_command
