#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 只停本机那个实例 —— run/ 是 CPFS 共享的，别的机器的 pid 在这里也看得到，
# 但那些进程不在本机，kill 不到（甚至可能误杀本机同号进程）。
PID="$HERE/run/proxy.$(hostname -s).pid"

[ -f "$PID" ] || { echo "本机没在跑"; exit 0; }

P="$(cat "$PID")"
if kill -0 "$P" 2>/dev/null; then
    # --num_workers 会 fork 子进程，杀整个进程组
    PGID="$(ps -o pgid= "$P" | tr -d ' ')"
    kill -TERM "-$PGID" 2>/dev/null || kill -TERM "$P" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
    kill -0 "$P" 2>/dev/null && kill -KILL "-$PGID" 2>/dev/null || true
    echo "已停止 (pid $P)"
else
    echo "pid $P 已不在"
fi
rm -f "$PID"
