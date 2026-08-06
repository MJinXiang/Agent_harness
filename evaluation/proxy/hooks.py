"""顶掉 rewardkit 写死的 max_tokens。

为什么要用 hook 而不是配置项：
    rewardkit 把 max_tokens 写死成 4096（judges.py:238，字面量，LLMJudge 模型里
    没有这个字段所以 toml 也改不了），而 toml 里 reasoning_effort="high" 会被
    转成 thinking:{"type":"adaptive"}。思考一放开就能把 4096 全烧光、正文一个字
    不写，于是 content=null，rewardkit 在 judges.py:137 拿它去 re.search 直接
    TypeError；那个 except 只接 ValueError/JSONDecodeError 兜不住，整题报
    RewardFileNotFoundError。5 个维度跑在同一个 asyncio.TaskGroup 里，一个炸掉
    其余的一起取消。

    实测证据（proxy DEBUG 日志）：
        崩掉那条  finish_reason=length  completion_tokens=4096  content=null
        正常那条  finish_reason=stop    completion_tokens=2396  reasoning_tokens=1059

    试过 config.yaml 里 additional_drop_params: ["max_tokens"] + litellm_params
    里给大值，无效 —— 发给上游的 body 仍是 4096。因为这条链路是
    /v1/messages -> anthropic_messages 桥接 -> chat completions，不经过
    get_optional_params，而 additional_drop_params 是在那里生效的。
    pre-call hook 在桥接之前动 data，是能改到的地方。
"""

from typing import Any, Literal, Optional

from litellm.integrations.custom_logger import CustomLogger

# claude-sonnet-4.6 输出上限 64k，32000 留足余量：
# 思考约 1000-4000，正文（16 条 criterion 各一段 reasoning）几千。
MIN_MAX_TOKENS = 32000


class CapMaxTokens(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: Literal[
            "completion",
            "text_completion",
            "embeddings",
            "image_generation",
            "moderation",
            "audio_transcription",
            "pass_through_endpoint",
            "rerank",
            "mcp_call",
        ],
    ) -> Optional[dict]:
        current = data.get("max_tokens")
        if not isinstance(current, int) or current < MIN_MAX_TOKENS:
            data["max_tokens"] = MIN_MAX_TOKENS
        return data


cap = CapMaxTokens()
