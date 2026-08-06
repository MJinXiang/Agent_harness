#!/usr/bin/env python3
"""汇总一次评测的结果，按数据来源分组给出得分。

    ./summarize.py jobs/<job-name>                    # 表格
    ./summarize.py jobs/<job-name> --format csv       # 逐题 CSV
    ./summarize.py jobs/<job-name> --dataset <数据集目录>

不传 job 目录时取 jobs/ 下最新的一个。

需要 Python 3.7+。系统 python3 太老时改用 harbor venv 里的那个：
    ../.venv/bin/python summarize.py
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from io import StringIO
from pathlib import Path
from typing import TextIO

SCRIPT_DIR = Path(__file__).resolve().parent

if sys.version_info < (3, 7):
    # 3.6 及更早没有 dataclasses，也不认 `from __future__ import annotations`，
    # 上面的 import 早就炸了 —— 这行只是给万一走到这里的人一个明确指引。
    sys.exit(
        "需要 Python 3.7+，当前是 %d.%d。改用 harbor venv 里的解释器：\n"
        "    %s/../.venv/bin/python %s"
        % (sys.version_info[0], sys.version_info[1], SCRIPT_DIR, " ".join(sys.argv))
    )


@dataclass
class TrialRow:
    task_dir: str
    source: str
    reward: float | None
    error: str | None
    dimensions: dict[str, float] = field(default_factory=dict)


def dataset_path_from_env() -> str:
    """从 evaluation/.env 里捞 DATASET_PATH，省得两处填。"""
    env_file = SCRIPT_DIR / ".env"
    if not env_file.is_file():
        return ""
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line.startswith("DATASET_PATH=") and not line.startswith("#"):
            return line.split("=", 1)[1].strip().strip("'\"")
    return ""


def load_source_map(dataset_path: Path) -> dict[str, str]:
    """任务目录名 -> 数据来源，取自数据集的 index.json。"""
    index_file = dataset_path / "index.json"
    if not index_file.is_file():
        return {}
    index = json.loads(index_file.read_text())
    return {t["task"]: t["source"] for t in index.get("tasks", [])}


def iter_results(job_dir: Path) -> list[Path]:
    return sorted(job_dir.rglob("results.json"))


def parse_trial(results_file: Path, source_map: dict[str, str]) -> TrialRow | None:
    try:
        data = json.loads(results_file.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"跳过 {results_file}: {exc}", file=sys.stderr)
        return None

    # task_id.path 的 basename 才是任务目录名；task_name 是 task.toml 里的
    # name 字段，ALE 那批与目录名并不一致。
    task_path = (data.get("task_id") or {}).get("path", "")
    task_dir = Path(task_path).name if task_path else data.get("task_name", "?")

    verifier = data.get("verifier_result") or {}
    rewards = verifier.get("rewards") or {}
    reward = rewards.get("reward")

    exception_info = data.get("exception_info") or {}
    error = exception_info.get("exception_type") or exception_info.get(
        "exception_message"
    )

    return TrialRow(
        task_dir=task_dir,
        source=source_map.get(task_dir, "unknown"),
        reward=float(reward) if isinstance(reward, (int, float)) else None,
        error=error,
        dimensions={k: v for k, v in rewards.items() if k != "reward"},
    )


def display_width(text: str) -> int:
    """字符串在等宽终端里占的列数。中日韩字符占两列。"""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def pad(text: str, width: int, align: str = "<") -> str:
    """按显示宽度而非字符数对齐 —— 表头是中文，用 f-string 的 :<28 会歪。"""
    filler = " " * max(0, width - display_width(text))
    return text + filler if align == "<" else filler + text


COLUMNS = [
    ("来源", 26, "<"),
    ("题数", 6, ">"),
    ("已评分", 8, ">"),
    ("均分", 9, ">"),
    ("中位", 9, ">"),
    ("满分", 7, ">"),
    ("零分", 7, ">"),
    ("报错", 7, ">"),
]
TABLE_WIDTH = sum(w for _, w, _ in COLUMNS)


def print_table(rows: list[TrialRow]) -> None:
    by_source: dict[str, list[TrialRow]] = defaultdict(list)
    for row in rows:
        by_source[row.source].append(row)

    print("".join(pad(title, w, a) for title, w, a in COLUMNS))
    print("─" * TABLE_WIDTH)

    def emit(label: str, group: list[TrialRow]) -> None:
        scored = [r.reward for r in group if r.reward is not None]
        errors = sum(1 for r in group if r.error)
        cells = [
            label,
            str(len(group)),
            str(len(scored)),
            f"{statistics.mean(scored):.4f}" if scored else "—",
            f"{statistics.median(scored):.4f}" if scored else "—",
            str(sum(1 for s in scored if s >= 0.999)),
            str(sum(1 for s in scored if s <= 0.001)),
            str(errors),
        ]
        print("".join(pad(c, w, a) for c, (_, w, a) in zip(cells, COLUMNS)))

    for source in sorted(by_source):
        emit(source, by_source[source])

    print("─" * TABLE_WIDTH)
    emit("总计", rows)

    # 未评分的题往往是真问题（verifier 崩了、judge 没 key、超时），单独点名。
    unscored = [r for r in rows if r.reward is None]
    if unscored:
        print(f"\n{len(unscored)} 题没有得分：")
        reasons: dict[str, list[str]] = defaultdict(list)
        for row in unscored:
            reasons[row.error or "无 reward 且无异常记录"].append(row.task_dir)
        for reason, names in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
            shown = ", ".join(names[:8])
            more = f" …等 {len(names)} 题" if len(names) > 8 else ""
            print(f"  {reason}: {shown}{more}")


def write_csv(rows: list[TrialRow], out: TextIO) -> None:
    dimension_keys = sorted({k for r in rows for k in r.dimensions})
    writer = csv.writer(out)
    writer.writerow(["task", "source", "reward", "error", *dimension_keys])
    for row in sorted(rows, key=lambda r: r.task_dir):
        writer.writerow(
            [
                row.task_dir,
                row.source,
                "" if row.reward is None else f"{row.reward:.6f}",
                row.error or "",
                *[row.dimensions.get(k, "") for k in dimension_keys],
            ]
        )


def resolve_job_dir(raw: str | None) -> Path:
    if raw:
        job_dir = Path(raw).expanduser()
        if not job_dir.is_absolute():
            job_dir = (Path.cwd() / job_dir).resolve()
        if not job_dir.is_dir():
            raise SystemExit(f"job 目录不存在: {job_dir}")
        return job_dir

    jobs_root = SCRIPT_DIR / "jobs"
    if not jobs_root.is_dir():
        raise SystemExit(f"没传 job 目录，且 {jobs_root} 不存在。")
    candidates = [p for p in jobs_root.iterdir() if p.is_dir()]
    if not candidates:
        raise SystemExit(f"{jobs_root} 下没有 job。")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "job_dir", nargs="?", help="job 输出目录，默认取 jobs/ 下最新的"
    )
    parser.add_argument(
        "--dataset",
        default="",
        help="数据集目录，用于读 index.json 做来源映射。默认读 .env 的 DATASET_PATH",
    )
    parser.add_argument("--format", choices=["table", "csv"], default="table")
    parser.add_argument("-o", "--output", help="CSV 输出路径，默认写到标准输出")
    args = parser.parse_args()

    job_dir = resolve_job_dir(args.job_dir)

    raw_dataset = args.dataset or dataset_path_from_env()
    if not raw_dataset:
        print(
            "不知道数据集在哪（--dataset 没给，.env 里也没有 DATASET_PATH），"
            "来源一律记为 unknown。",
            file=sys.stderr,
        )
        source_map: dict[str, str] = {}
    else:
        dataset_path = Path(raw_dataset).expanduser()
        if not dataset_path.is_absolute():
            dataset_path = (SCRIPT_DIR / dataset_path).resolve()
        source_map = load_source_map(dataset_path)
        if not source_map:
            print(
                f"读不到 {dataset_path}/index.json，来源一律记为 unknown。",
                file=sys.stderr,
            )

    result_files = iter_results(job_dir)
    if not result_files:
        raise SystemExit(f"{job_dir} 下没有 results.json。")

    parsed = (parse_trial(f, source_map) for f in result_files)
    rows = [row for row in parsed if row is not None]

    if args.format == "csv":
        if args.output:
            buffer = StringIO()
            write_csv(rows, buffer)
            Path(args.output).write_text(buffer.getvalue(), encoding="utf-8")
            print(f"已写入 {args.output}", file=sys.stderr)
        else:
            write_csv(rows, sys.stdout)
    else:
        print(f"\njob: {job_dir}\n")
        print_table(rows)


if __name__ == "__main__":
    main()
