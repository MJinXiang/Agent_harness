# 评测

在数据集上评测一个 Anthropic 兼容端点。数据集路径在 `.env` 的 `DATASET_PATH`。

```
evaluation/
├── run_eval.sh       跑评测，配置读 .env
├── summarize.py      汇总得分，按数据来源分组
├── env.example       配置模板（.env 被 gitignore，key 直接写）
└── proxy/            裁判网关，只有需要换裁判模型时才用
    ├── start.sh / stop.sh / selftest.sh
    ├── config.yaml   模型名映射
    ├── hooks.py      把 rewardkit 写死的 max_tokens 4096 顶到 32000
    └── env.example   上游端点 / key / 真正的裁判模型
```

## 用法

**1. 起裁判网关**（`proxy/`）

benchmark 的 `tests/*/*.toml` 把裁判写死成 `anthropic/claude-sonnet-4-6`，
rewardkit 也不读环境变量，所以除非你有 Anthropic 官方 key，都得靠这层网关
把模型名换成你的上游认识的名字。顺便把 rewardkit 写死的 `max_tokens=4096`
顶大——不然推理模型会把额度全烧在思考上，正文为空导致整题崩。

```bash
cd proxy
cp env.example .env        # 填上游端点、key、裁判模型
./start.sh                 # 打印本机 IP，evaluation/.env 要用
./selftest.sh              # 两枪都拿到 content 才算通
```

换上游只改 `proxy/.env` 三行，`config.yaml` 不用动。上游有 Anthropic 端点就
优先用（`anthropic/` 前缀），别走 OpenAI 接口——推理模型的 thinking block
缺 signature，客户端会校验失败。

**2. 配置评测**

```bash
cp env.example .env
```

被测模型填 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `MODEL`；
裁判那三行指向上一步起的网关（`JUDGE_ANTHROPIC_BASE_URL` 填网关地址，
**不能写 127.0.0.1**，那是 verifier 容器自己）。

**3. 跑**

```bash
./run_eval.sh --task task_00001    # 先single题探路
./run_eval.sh                      # 按 .env 的 PRESET 跑
./summarize.py                     # 看分
```

`--task` 接任务目录名或 glob，可重复，会顶掉 `.env` 里的 `PRESET`/`SOURCES`/`N_TASKS`。
`--dry-run` 只打印将执行的 harbor 命令。

调 judge 时可以用 `--agent oracle` 跳过 agent 那几分钟（只有 sciprobench 和
ws_hardest 有真的参考解，其余任务的 oracle 是空壳、分数为 0，但足够验证链路）。

## 前置条件

需要能用的 Docker daemon。harbor 和 python 都按「先 `<repo>/.venv`、后 `PATH`」找，
`--dry-run` 会打印实际选中的路径。

## 三条评分管线

| 来源 | 题数 | 评分 | 要裁判吗 |
|---|---|---|---|
| sciprobench, harbor_chem195, harbor_cs300, gdp_pdf | 616 | RewardKit LLM rubric | 要 |
| env_long_horizon | 36 | RewardKit agent judge（容器内起 claude CLI 读工作区） | 要 |
| ws_hardest | 35 | 表格比对，逐字相同的单元格不调模型 | 看情况 |
| pujiang_ale100 | 100 | ALE 确定性 evaluator | 不要 |
| kernelbench_hard_operators | 2 | 正确性 + 速度，**需要 B200** | 不要 |

`PRESET=deterministic` 是后三类共 137 题。前 652 题都走 rewardkit，也就都吃
`max_tokens` 那个坑，必须经 proxy。

## 输出

```
jobs/<job-name>/<task>/<trial>/
├── results.json            含 verifier_result.rewards
├── verifier/reward.json    没有这个文件就是 judge 挂了
├── verifier/test-stdout.txt判分过程，排查看这里
└── agent/                  agent 日志与轨迹
```

`summarize.py` 按来源聚合，并单独列出没拿到分数的题——那类通常是配置问题
而不是模型能力问题。
