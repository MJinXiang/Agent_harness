#!/usr/bin/env bash
#
# 在数据集上评测一个自定义 Anthropic 兼容端点。
#
#   cp env.example .env          # 填好配置
#   ./run_eval.sh                # 按 .env 跑
#   ./run_eval.sh --dry-run      # 只打印将要执行的 harbor 命令
#   ./run_eval.sh --task task_00095          # 只跑这一题
#   ./run_eval.sh --task 'task_001*' -n 3    # glob + 最多 3 题
#
# 所有可调项都在 .env 里，本脚本不硬编码任何 key 或模型名。
# 命令行参数优先级高于 .env，方便调试时不改文件。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
CLI_TASKS=""
CLI_N_TASKS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -t|--task)
            [ $# -ge 2 ] || { echo "$1 需要一个任务名或 glob" >&2; exit 2; }
            CLI_TASKS="${CLI_TASKS:+$CLI_TASKS,}$2"
            shift
            ;;
        -n|--n-tasks)
            [ $# -ge 2 ] || { echo "$1 需要一个数字" >&2; exit 2; }
            CLI_N_TASKS="$2"
            shift
            ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "错误: $*" >&2; exit 1; }
warn() { echo "警告: $*" >&2; }

# harbor 要求 Python 3.12+，它的 venv 里那个一定够新。系统 python3 可能很老
# （见过 3.6 的机器），所以优先用 venv 的，实在没有再退回系统的。
if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    PYTHON_BIN="$REPO_ROOT/.venv/bin/python"
else
    PYTHON_BIN="${PYTHON_BIN:-python3}"
fi
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 python（$PYTHON_BIN）。"

# harbor 同理：优先 venv，其次 PATH。这里只解析不报错，好让 --dry-run
# 在还没装 harbor 的机器上也能用来检查配置；真要跑之前才拦。
HARBOR_BIN="${HARBOR_BIN:-}"
if [ -z "$HARBOR_BIN" ]; then
    if [ -x "$REPO_ROOT/.venv/bin/harbor" ]; then
        HARBOR_BIN="$REPO_ROOT/.venv/bin/harbor"
    elif command -v harbor >/dev/null 2>&1; then
        HARBOR_BIN="$(command -v harbor)"
    fi
fi

# ── 加载配置 ────────────────────────────────────────────────────
# set -a 让 source 进来的变量自动 export。这是必需的，不是图省事：
# claude_code.py:1378 只从 os.environ 读 ANTHROPIC_BASE_URL，
# 没 export 的话 harbor 看不到它，模型别名改写（1445-1449 行）不会触发，
# CLI 内部调 haiku 时会打到端点上不存在的模型。
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE。先 cp env.example .env 再填值。"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── 默认值 ──────────────────────────────────────────────────────
AGENT="${AGENT:-general_agent}"
JUDGE_MODE="${JUDGE_MODE:-anthropic}"
JUDGE_MODEL="${JUDGE_MODEL:-}"
DATASET_PATH="${DATASET_PATH:-}"
PRESET="${PRESET:-}"
SOURCES="${SOURCES:-}"
TASK_INCLUDE="${TASK_INCLUDE:-}"
TASK_EXCLUDE="${TASK_EXCLUDE:-}"
N_TASKS="${N_TASKS:-}"
ENV_TYPE="${ENV_TYPE:-docker}"
N_CONCURRENT="${N_CONCURRENT:-4}"
N_ATTEMPTS="${N_ATTEMPTS:-1}"
TIMEOUT_MULTIPLIER="${TIMEOUT_MULTIPLIER:-1.0}"
JOBS_DIR="${JOBS_DIR:-./jobs}"
FORCE_BUILD="${FORCE_BUILD:-false}"
DELETE="${DELETE:-true}"
MAX_RETRIES="${MAX_RETRIES:-0}"
JOB_NAME="${JOB_NAME:-}"
WS_JUDGE_MODEL="${WS_JUDGE_MODEL:-}"

# ── 命令行覆盖 ──────────────────────────────────────────────────
# --task 是精确点名，把 .env 里的 PRESET / SOURCES 一并让位，
# 否则 preset 选出的集合会和点名的题取交集，最后很可能是空的。
if [ -n "$CLI_TASKS" ]; then
    TASK_INCLUDE="$CLI_TASKS"
    PRESET=""
    SOURCES=""
    # .env 里的 N_TASKS 也让位：点名了 'task_001*' 却被上一次调试留下的
    # N_TASKS=4 悄悄截断，是个很难发现的坑。要限量就显式 -n。
    N_TASKS=""
fi
if [ -n "$CLI_N_TASKS" ]; then N_TASKS="$CLI_N_TASKS"; fi

# ── 校验被测模型配置 ────────────────────────────────────────────
[ -n "$DATASET_PATH" ] || die "DATASET_PATH 未设置，在 .env 里填数据集目录。"
[ -n "${MODEL:-}" ] || die "MODEL 未设置。"
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    die "ANTHROPIC_AUTH_TOKEN 和 ANTHROPIC_API_KEY 都为空，agent 无法鉴权。"
fi
[ -n "${ANTHROPIC_BASE_URL:-}" ] || warn "ANTHROPIC_BASE_URL 为空，将走 Anthropic 官方端点。"

# 路径按 evaluation/ 解析
case "$DATASET_PATH" in /*) ;; *) DATASET_PATH="$SCRIPT_DIR/$DATASET_PATH" ;; esac
case "$JOBS_DIR" in /*) ;; *) JOBS_DIR="$SCRIPT_DIR/$JOBS_DIR" ;; esac
[ -d "$DATASET_PATH" ] || die "数据集目录不存在: $DATASET_PATH"
INDEX_JSON="$DATASET_PATH/index.json"
[ -f "$INDEX_JSON" ] || die "找不到 $INDEX_JSON"

# ── 解析子集 ────────────────────────────────────────────────────
# 需要 judge 的来源；其余是确定性评分。
RUBRIC_SOURCES="sciprobench,env_long_horizon,harbor_chem195,harbor_cs300,gdp_pdf"
DETERMINISTIC_SOURCES="ws_hardest,pujiang_ale100,kernelbench_hard_operators"

SMOKE_PER_SOURCE=0
case "$PRESET" in
    smoke)         SOURCES=""; SMOKE_PER_SOURCE="${SMOKE_PER_SOURCE_N:-2}" ;;
    deterministic) SOURCES="$DETERMINISTIC_SOURCES" ;;
    rubric)        SOURCES="$RUBRIC_SOURCES" ;;
    all)           SOURCES="" ;;
    "")            ;;
    *)             die "未知 PRESET: $PRESET（可选 smoke / deterministic / rubric / all）" ;;
esac

# 把来源筛选 + glob 过滤统一解析成一份确定的任务目录名列表。
#
# 为什么在这里算而不是丢给 harbor 拼多个 --include-task-name：
# harbor 的多个 include 之间是 any() 匹配（models/job/config.py:126-128），
# 也就是并集；而"来源筛选再叠 glob"要的是交集。语义在这里定死，harbor 只收结果。
#
# 匹配的是任务目录名（models/task/id.py:29），不是 task.toml 里的 name ——
# ALE 那批两者并不相同。
SELECTED_TASKS=""
if [ -n "$SOURCES" ] || [ "$SMOKE_PER_SOURCE" -gt 0 ] \
   || [ -n "$TASK_INCLUDE" ] || [ -n "$TASK_EXCLUDE" ]; then
    SELECTED_TASKS="$(
        SOURCES="$SOURCES" SMOKE_N="$SMOKE_PER_SOURCE" \
        TASK_INCLUDE="$TASK_INCLUDE" TASK_EXCLUDE="$TASK_EXCLUDE" \
        "$PYTHON_BIN" - "$INDEX_JSON" <<'PY'
import fnmatch, json, os, sys
from collections import defaultdict
from pathlib import Path

tasks = json.loads(Path(sys.argv[1]).read_text())["tasks"]
smoke_n = int(os.environ["SMOKE_N"])


def split(name):
    return [p.strip() for p in os.environ[name].split(",") if p.strip()]


wanted = set(split("SOURCES"))
known = set(t["source"] for t in tasks)
unknown = wanted - known
if unknown:
    sys.exit(
        "index.json 里没有这些来源: %s\n可选: %s" % (sorted(unknown), sorted(known))
    )

if smoke_n > 0:
    # 每个来源取前 N 题，三条评分管线都覆盖到。
    by_source = defaultdict(list)
    for t in tasks:
        by_source[t["source"]].append(t["task"])
    picked = [n for names in by_source.values() for n in names[:smoke_n]]
elif wanted:
    picked = [t["task"] for t in tasks if t["source"] in wanted]
else:
    picked = [t["task"] for t in tasks]

# glob 与来源筛选取交集
includes = split("TASK_INCLUDE")
if includes:
    picked = [n for n in picked if any(fnmatch.fnmatch(n, p) for p in includes)]
excludes = split("TASK_EXCLUDE")
if excludes:
    picked = [n for n in picked if not any(fnmatch.fnmatch(n, p) for p in excludes)]

if not picked:
    sys.exit("筛选后没有任何任务，检查 PRESET / SOURCES / TASK_INCLUDE 的组合。")

print("\n".join(picked))
PY
    )" || die "解析任务子集失败"
fi

# ── 组装 harbor 参数 ────────────────────────────────────────────
args=(
    run
    --path "$DATASET_PATH"
    --agent "$AGENT"
    --model "$MODEL"
    --env "$ENV_TYPE"
    --n-concurrent "$N_CONCURRENT"
    --n-attempts "$N_ATTEMPTS"
    --timeout-multiplier "$TIMEOUT_MULTIPLIER"
    --jobs-dir "$JOBS_DIR"
    --max-retries "$MAX_RETRIES"
    --yes
)

if [ "$FORCE_BUILD" = "true" ]; then args+=(--force-build); else args+=(--no-force-build); fi
if [ "$DELETE" = "true" ]; then args+=(--delete); else args+=(--no-delete); fi
if [ -n "$JOB_NAME" ]; then args+=(--job-name "$JOB_NAME"); fi

# SELECTED_TASKS 已经是交集与排除都算完的最终列表，逐个传给 harbor。
if [ -n "$SELECTED_TASKS" ]; then
    while IFS= read -r name; do
        if [ -n "$name" ]; then args+=(--include-task-name "$name"); fi
    done <<< "$SELECTED_TASKS"
fi

if [ -n "$N_TASKS" ]; then args+=(--n-tasks "$N_TASKS"); fi

# ── Judge 配置 ──────────────────────────────────────────────────
# verifier 的环境是 task.toml 的 [verifier.env] 与 --ve 合并而成
# （verifier/verifier.py:159-163），--ve 传字面值并覆盖 toml 里的 ${VAR:-} 模板。
# 宿主机其余环境变量不会泄漏进 verifier，所以被测端点的 ANTHROPIC_BASE_URL
# 不会污染裁判 —— 除非 JUDGE_MODE=self 显式传进去。
case "$JUDGE_MODE" in
    anthropic)
        [ -n "${JUDGE_ANTHROPIC_API_KEY:-}" ] \
            || die "JUDGE_MODE=anthropic 但 JUDGE_ANTHROPIC_API_KEY 为空。"
        args+=(--ve "ANTHROPIC_API_KEY=$JUDGE_ANTHROPIC_API_KEY")
        # 留空走官方端点。填了就是另一个 Anthropic 兼容代理当裁判 ——
        # 与被测端点无关，两者互不影响。
        if [ -n "${JUDGE_ANTHROPIC_BASE_URL:-}" ]; then
            args+=(--ve "ANTHROPIC_API_BASE=$JUDGE_ANTHROPIC_BASE_URL")
            args+=(--ve "ANTHROPIC_BASE_URL=$JUDGE_ANTHROPIC_BASE_URL")
        fi
        ;;
    openai)
        [ -n "${JUDGE_OPENAI_API_KEY:-}" ] \
            || die "JUDGE_MODE=openai 但 JUDGE_OPENAI_API_KEY 为空。"
        args+=(--ve "OPENAI_API_KEY=$JUDGE_OPENAI_API_KEY")
        if [ -n "${JUDGE_OPENAI_BASE_URL:-}" ]; then
            args+=(--ve "OPENAI_BASE_URL=$JUDGE_OPENAI_BASE_URL")
        fi
        [ -n "$JUDGE_MODEL" ] \
            || die "JUDGE_MODE=openai 时必须设 JUDGE_MODEL（如 openai/gpt-4.1）。"
        ;;
    self)
        warn "JUDGE_MODE=self：被测模型给自己打分，存在自评偏差。"
        args+=(--ve "ANTHROPIC_API_KEY=${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}")
        if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            # LiteLLM 认 ANTHROPIC_API_BASE；ANTHROPIC_BASE_URL 一并传上以防万一。
            args+=(--ve "ANTHROPIC_API_BASE=$ANTHROPIC_BASE_URL")
            args+=(--ve "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
        fi
        [ -n "$JUDGE_MODEL" ] || JUDGE_MODEL="anthropic/$MODEL"
        ;;
    none)
        if [ "$PRESET" != "deterministic" ]; then
            warn "JUDGE_MODE=none 但子集里可能含 rubric 任务，那些题会判 0 分。"
        fi
        warn "ws_hardest 那 35 题在无 key 时，非逐字相同的单元格一律判为不等，得分偏低。"
        ;;
    *)
        die "未知 JUDGE_MODE: $JUDGE_MODE（可选 anthropic / openai / self / none）"
        ;;
esac

# 只有 ws_hardest 吃这个变量（数据集自带的 tests/evaluate.py:39 读它）。
# rubric 那 652 题换不了裁判 —— 容器里的 rewardkit 0.1.0 只认 toml 的
# [judge].judge，不读环境变量（runner.py:64），只能在 BASE_URL 那层重写模型名。
ws_judge="${WS_JUDGE_MODEL:-$JUDGE_MODEL}"
if [ -n "$ws_judge" ]; then args+=(--ve "WS_JUDGE_MODEL=$ws_judge"); fi

# ── 跑 ──────────────────────────────────────────────────────────
if [ -n "$SELECTED_TASKS" ]; then
    n_selected="$(printf '%s\n' "$SELECTED_TASKS" | grep -c . || true)"
else
    n_selected="全部"
fi
cat >&2 <<EOF

  数据集   $DATASET_PATH
  任务数   $n_selected${PRESET:+  (preset=$PRESET)}
  agent    $AGENT
  模型     $MODEL @ ${ANTHROPIC_BASE_URL:-官方端点}
  裁判     ${JUDGE_MODEL:-数据集默认值}  (JUDGE_MODE=$JUDGE_MODE)
  环境     $ENV_TYPE  并发 $N_CONCURRENT  重复 $N_ATTEMPTS
  输出     $JOBS_DIR
  harbor   ${HARBOR_BIN:-未找到（跑之前要先装）}
  python   $PYTHON_BIN

EOF

if [ "$DRY_RUN" = "1" ]; then
    # 打印命令：key 打码，成片的 --include-task-name 折叠成一行摘要。
    printf 'harbor'
    skip_next=0
    shown_includes=0
    for a in "${args[@]}"; do
        if [ "$skip_next" = "1" ]; then skip_next=0; continue; fi
        if [ "$a" = "--include-task-name" ]; then
            skip_next=1
            shown_includes=$((shown_includes + 1))
            continue
        fi
        case "$a" in
            *KEY=?*|*TOKEN=?*) printf ' %s=***' "${a%%=*}" ;;
            *)                 printf ' %q' "$a" ;;
        esac
    done
    if [ "$shown_includes" -gt 0 ]; then
        first="$(printf '%s\n' "$SELECTED_TASKS" | head -1)"
        last="$(printf '%s\n' "$SELECTED_TASKS" | tail -1)"
        printf ' \\\n  # + %d 个 --include-task-name (%s … %s)' \
            "$shown_includes" "$first" "$last"
    fi
    printf '\n'
    exit 0
fi

if [ -z "$HARBOR_BIN" ]; then
    die "找不到 harbor。在仓库根目录跑 uv sync --all-extras --dev，
   或 uv tool install harbor，或设 HARBOR_BIN 指向已有的可执行文件。
   不需要 source .venv/bin/activate —— 本脚本用绝对路径调它。"
elif ! command -v "$HARBOR_BIN" >/dev/null 2>&1; then
    # 只有显式传 HARBOR_BIN 才会走到这里，自动探测出来的一定存在。
    die "HARBOR_BIN 指向的文件不存在或不可执行: $HARBOR_BIN"
fi

exec "$HARBOR_BIN" "${args[@]}"
