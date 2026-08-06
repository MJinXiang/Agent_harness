#!/usr/bin/env bash
#
# 用 litellm 完全复刻 rewardkit 的调用去打网关，确认拿得到非空 content。
#
# 为什么不用 curl：rewardkit 走的是 litellm.acompletion，它会把
# reasoning_effort 转成 Anthropic 的 thinking、把 response_format 转成
# output_config 再发出去（judges.py:236-242）。curl 手搓的简单请求打不出
# 这两个参数，测了也不算数 —— 之前就是这么漏掉问题的。
#
# 需要能 import litellm（跟起网关是同一个环境，activate 后跑）。

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
[ -f "$ENV_FILE" ] || { echo "找不到 $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${PROXY_MASTER_KEY:=sk-judge-local}"
: "${PROXY_PORT:=4100}"

export ANTHROPIC_API_KEY="$PROXY_MASTER_KEY"
export ANTHROPIC_API_BASE="http://127.0.0.1:$PROXY_PORT"
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"

python3 - <<'PY'
import os, sys, litellm

# 与 rewardkit judges.py:236-242 完全一致
COMMON = dict(
    messages=[
        {"role": "system", "content": "You are a grader. Reply with a JSON object."},
        {"role": "user", "content": [
            {"type": "text", "text": 'Grade this. Reply exactly: ```json\n{"ok": 1}\n```'}
        ]},
    ],
    response_format={"type": "json_object"},
    max_tokens=4096,
    timeout=900,
    reasoning_effort="high",
)

# 两类裁判让网关收到的模型名不同。LiteLLM 会剥掉第一段 provider 前缀，
# 所以这里多套一层 anthropic/ 来构造出 agent judge 那个带前缀的名字：
#   LLM judge   网关收到 claude-sonnet-4-6
#   agent judge 网关收到 anthropic/claude-sonnet-4-6
# 注意 agent judge 真实走的是 claude CLI 而不是 LiteLLM，不会带 thinking
# 参数；这里只是借 LiteLLM 验证网关对那个名字的映射，属于近似。
CASES = [
    ("LLM judge（652 题）", "anthropic/claude-sonnet-4-6"),
    ("agent judge（36 题）", "anthropic/anthropic/claude-sonnet-4-6"),
]

failed = 0
for label, model in CASES:
    sent = model.split("/", 1)[1]  # LiteLLM 发出去的名字
    print(f"── {label}：网关会收到 model={sent}")
    try:
        r = litellm.completion(model=model, **COMMON)
    except Exception as exc:
        print(f"   失败 {type(exc).__name__}: {str(exc)[:300]}\n")
        failed += 1
        continue

    msg = r.choices[0].message
    content = msg.content
    if not content or not str(content).strip():
        # 这就是 rewardkit 崩溃的那个点
        print("   content 为空 —— rewardkit 会在 judges.py:137 re.search(None) 崩掉")
        print(f"   finish_reason     = {r.choices[0].finish_reason}")
        print(f"   reasoning_content = {repr(getattr(msg, 'reasoning_content', None))[:200]}")
        print(f"   完整 message      = {repr(msg)[:300]}\n")
        failed += 1
        continue

    print(f"   OK  -> {repr(content)[:120]}")
    print(f"   上游实际用的模型: {r.model}")
    usage = getattr(r, "usage", None)
    if usage:
        print(f"   tokens: 入 {usage.prompt_tokens} 出 {usage.completion_tokens}")
    print()

sys.exit(1 if failed else 0)
PY
