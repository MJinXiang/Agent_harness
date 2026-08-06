#!/usr/bin/env bash
#
#   cp env.example .env   # 填上游端点、key、真正的裁判模型
#   ./start.sh            # 后台起，等就绪，打印 evaluation/.env 该填什么
#   ./stop.sh
#   tail -f run/proxy.log
#
# 起在哪台机器都行，只要 verifier 容器访问得到本机 IP:端口、本机访问得到上游。
# 换上游只改 .env，config.yaml 不用动。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "错误: $*" >&2; exit 1; }

# ── 加载配置 ────────────────────────────────────────────────────
# set -a 让变量自动 export：config.yaml 里的 os.environ/XXX 从进程环境读。
ENV_FILE="${ENV_FILE:-$HERE/.env}"
[ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE。先 cp env.example .env 再填值。"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${UPSTREAM_MODEL:=}"
: "${UPSTREAM_BASE_URL:=}"
: "${UPSTREAM_API_KEY:=}"
: "${PROXY_MASTER_KEY:=sk-judge-local}"
: "${PROXY_PORT:=4100}"
: "${PROXY_WORKERS:=4}"
: "${PROXY_LOG:=ERROR}"

[ -n "$UPSTREAM_MODEL" ]   || die "UPSTREAM_MODEL 为空。"
[ -n "$UPSTREAM_API_KEY" ] || die "UPSTREAM_API_KEY 为空。"
# BASE_URL 允许为空（openrouter/ 和 deepseek/ 这类原生 provider 有默认端点），
# 但 config.yaml 里 api_base 是 os.environ/ 引用，变量必须存在，给个空串。
export UPSTREAM_BASE_URL PROXY_MASTER_KEY
export LITELLM_LOG="$PROXY_LOG"

# 这台机器上有 squid 代理，内网上游必须绕开它，否则请求会被劫走然后挂住。
# 只写 10.0.0.0/8 不够 —— httpx 对 NO_PROXY 的 CIDR 支持不可靠，得给具体 host。
# 公网上游（如 openrouter.ai）则要留着代理，所以不能一股脑 unset。
_upstream_host="$(printf '%s' "$UPSTREAM_BASE_URL" | sed -E 's#^[a-z]+://##; s#[:/].*##')"
export NO_PROXY="127.0.0.1,localhost,::1${_upstream_host:+,$_upstream_host}${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
echo "  NO_PROXY   $NO_PROXY" >&2

command -v litellm >/dev/null 2>&1 \
    || die "找不到 litellm。先 pip install --trusted-host mirrors.aliyun.com 'litellm[proxy]'"

# run/ 在 CPFS 上，多台机器共享同一份。文件名带 hostname，
# 否则两台机器各起一个实例时 pid 会互相覆盖，stop.sh 会杀错进程。
mkdir -p "$HERE/run"
LOG="$HERE/run/proxy.$(hostname -s).log"
PID="$HERE/run/proxy.$(hostname -s).pid"

if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    die "已经在跑了（pid $(cat "$PID")）。先 ./stop.sh"
fi

cat >&2 <<EOF

  上游模型   $UPSTREAM_MODEL
  上游端点   ${UPSTREAM_BASE_URL:-（provider 默认）}
  监听       0.0.0.0:$PROXY_PORT   workers=$PROXY_WORKERS
  日志       $LOG

EOF

nohup litellm --config "$HERE/config.yaml" \
    --host 0.0.0.0 --port "$PROXY_PORT" --num_workers "$PROXY_WORKERS" \
    >"$LOG" 2>&1 &
echo $! > "$PID"

for i in $(seq 1 90); do
    if curl -sf --noproxy '*' "http://127.0.0.1:$PROXY_PORT/health/liveliness" \
        >/dev/null 2>&1; then
        IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
        cat <<EOF
就绪（$((i*2))s）  pid $(cat "$PID")

evaluation/.env 里填：

  JUDGE_ANTHROPIC_API_KEY=$PROXY_MASTER_KEY
  JUDGE_ANTHROPIC_BASE_URL=http://$IP:$PROXY_PORT

BASE_URL 两个注意点：不要带 /v1（LiteLLM 客户端会自己拼 /v1/messages）；
不能写 127.0.0.1（那是 verifier 容器自己，不是本机）。

自检：
  ./selftest.sh
EOF
        exit 0
    fi
    kill -0 "$(cat "$PID")" 2>/dev/null || { echo "进程已退出：" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 2
done

echo "错误: 180s 内没就绪，看 $LOG" >&2
tail -20 "$LOG" >&2
exit 1
