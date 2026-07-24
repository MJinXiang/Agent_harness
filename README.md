# Agent 评测与运行框架使用说明

本仓库提供一套用于运行、评测和分析 AI Agent 的完整工具链。它可以把任务放入隔离环境中执行，调用不同的 Agent 和模型，运行自动验证器，并将每次执行的轨迹、日志、奖励和异常统一保存下来。

本文档以“如何使用当前仓库”为主，覆盖环境准备、安装、首次运行、任务编写、批量配置、结果查看、开发测试和常见问题。

## 1. 适用场景

你可以使用本仓库完成以下工作：

- 在 Docker 或云端沙箱中运行 Agent；
- 对同一批任务测试不同 Agent、模型和参数；
- 运行本地任务、公开数据集或自定义数据集；
- 并发执行多次尝试，并自动汇总通过率和奖励；
- 保存 Agent 轨迹、终端记录、验证器日志和产物；
- 创建自己的任务、环境和验证规则；
- 通过网页查看器分析任务结果和失败原因；
- 为强化学习或其他训练流程生成 rollout 数据。

### 1.1 支持评测的 Agent Harness

当前仓库已经内置多种 Agent Harness 的安装、启动和结果采集适配。运行时通过 `-a` / `--agent` 选择：

```bash
harbor run \
  -p <任务或数据集路径> \
  -a <agent-harness> \
  -m <模型名称>
```

内置名称如下：

| 类别 | `--agent` 名称 | 说明 |
| --- | --- | --- |
| 主流编码 CLI | `claude-code`、`codex`、`gemini-cli`、`copilot-cli`、`cursor-cli`、`cline-cli` | 评测常见交互式或自动化编码 CLI |
| 开源编码 Agent | `aider`、`opencode`、`openhands`、`openhands-sdk`、`goose`、`mini-swe-agent`、`swe-agent` | 适用于代码修改、终端操作和 SWE 类任务 |
| 模型厂商或平台 Agent | `antigravity-cli`、`antigravity-sdk`、`rovodev-cli`、`trae-agent`、`devin` | 对接相应平台的 CLI、SDK 或托管 Agent |
| 其他 Agent Harness | `grok-build`、`hermes`、`nemo-agent`、`openclaw`、`kimi-code`、`kimi-cli`、`qwen-coder`、`deerflow`、`mimo`、`pi`、`vibe` | 对接各自的安装和运行方式 |
| Agent 框架 | `langgraph`、`dspy-rlm`、`eve` | 评测由框架或 SDK 驱动的 Agent |
| 计算机操作 | `computer-1` | 用于计算机操作类任务和相关模型后端 |
| 仓库内置 Agent | `terminus-2` | 仓库提供的通用终端 Agent |
| 测试工具 | `oracle`、`nop` | `oracle` 运行参考解法；`nop` 不执行操作，适合测试执行链路 |

此外还支持两种扩展方式：

1. **ACP Agent**：通过 Agent Client Protocol 接入兼容 Agent。可以使用 `acp:<agent>` 简写；具体用法参见 [`docs/content/docs/agents/acp.mdx`](docs/content/docs/agents/acp.mdx)。
2. **自定义 Python Agent**：将实现类的导入路径直接传给 `--agent`，例如 `my_package.my_agent:MyAgent`。自定义类应实现 `src/harbor/agents/base.py` 定义的 Agent 接口。

注意：不同 Harness 的安装命令、鉴权变量、模型参数和操作系统支持并不相同。某个 Harness 出现在列表中，表示仓库已有适配，不代表无需安装其上游 CLI 或配置账号。实际可用列表以 [`src/harbor/models/agent/name.py`](src/harbor/models/agent/name.py) 和 [`src/harbor/agents/factory.py`](src/harbor/agents/factory.py) 为准；各适配器实现位于 [`src/harbor/agents/installed/`](src/harbor/agents/installed/)。

## 2. 仓库结构

```text
.
├── src/harbor/          # Python 核心代码与 CLI
│   ├── agents/          # Agent 实现
│   ├── environments/    # Docker 和云端执行环境
│   ├── cli/             # 命令行入口
│   ├── models/          # 配置与结果数据模型
│   ├── orchestrators/   # 并发调度
│   └── verifier/        # 任务验证
├── examples/
│   ├── tasks/           # 可直接运行的示例任务
│   ├── configs/         # Agent、环境和功能配置示例
│   ├── agents/          # 自定义 Agent 示例
│   └── metrics/         # 自定义指标示例
├── adapters/            # 外部数据集转换工具
├── apps/viewer/         # 结果查看器前端
├── docs/                # 文档网站源码
├── tests/               # 单元、集成和运行时测试
├── packages/            # 工作区子包
├── jobs/                # 默认任务运行结果目录
└── pyproject.toml       # Python 项目和依赖配置
```

## 3. 环境要求

### 必需环境

- Python 3.12 或更高版本；
- [uv](https://docs.astral.sh/uv/)；
- Git。

### 本地沙箱运行

使用默认的 Docker 环境时，还需要：

- Docker Engine 或 Docker Desktop；
- 当前用户具有运行 Docker 容器的权限；
- Docker daemon 已启动。

检查环境：

```bash
python3 --version
uv --version
docker version
```

云端环境不一定依赖本机 Docker，但需要安装对应的可选依赖并配置服务商凭据。

## 4. 安装

### 4.1 从当前仓库安装（开发者推荐）

克隆仓库后，在仓库根目录执行：

```bash
uv sync --all-extras --dev
```

之后通过 `uv run` 使用 CLI：

```bash
uv run harbor --version
uv run harbor --help
```

本仓库同时注册了 `harbor`、`hr` 和 `hb` 三个等价入口。本文统一使用 `harbor`。

### 4.2 仅安装已发布版本

如果只需要使用 CLI，不准备修改源码：

```bash
uv tool install harbor
```

也可以使用 pip：

```bash
pip install harbor
```

安装后检查：

```bash
harbor --version
harbor --help
```

### 4.3 安装云环境依赖

从源码开发时，`uv sync --all-extras --dev` 已安装项目声明的全部开发依赖。只安装发行包时，可以按需选择额外依赖，例如：

```bash
pip install "harbor[daytona]"
pip install "harbor[modal]"
pip install "harbor[e2b]"
pip install "harbor[cloud]"
```

可用 extras 以 `pyproject.toml` 中的 `[project.optional-dependencies]` 为准。

## 5. 第一次运行

下面先用仓库自带的 `hello-world` 任务和 `oracle` Agent 验证整个执行链路。`oracle` 会运行任务自带的参考解法，不需要模型 API Key，适合检查 Docker、任务环境和验证器是否正常。

```bash
uv run harbor run \
  -p examples/tasks/hello-world \
  -a oracle
```

已通过工具方式安装时，去掉 `uv run` 即可：

```bash
harbor run -p examples/tasks/hello-world -a oracle
```

执行过程通常包括：

1. 读取任务配置与指令；
2. 构建或启动隔离环境；
3. 安装并运行 Agent；
4. 执行验证器；
5. 保存结果并输出奖励统计；
6. 按配置停止或删除环境。

默认结果写入 `jobs/`。

## 6. 使用真实 Agent 和模型

通用命令格式：

```bash
harbor run \
  -p <任务或本地数据集路径> \
  -a <agent> \
  -m <模型名称>
```

例如：

```bash
export ANTHROPIC_API_KEY="<your-api-key>"

harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/<model-name>
```

模型名和所需环境变量取决于 Agent 与模型服务商。密钥不要写入仓库或提交到 Git。

### 6.1 向 Agent 传递环境变量

使用 `--ae` 或 `--agent-env`：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a <agent> \
  -m <model> \
  --ae API_KEY="$API_KEY" \
  --ae AWS_REGION=us-east-1
```

该参数可以重复使用。也可以通过 `--env-file` 加载环境变量文件；运行前可先查看最终解析配置：

```bash
harbor run -c path/to/config.yaml --print-config
```

### 6.2 Agent 参数

通过可重复的 `--ak key=value` 传入 Agent 构造参数：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a <agent> \
  -m <model> \
  --ak temperature=0.2
```

自定义 Agent 也可以直接使用 Python 导入路径：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a my_package.my_agent:MyAgent
```

具体 Agent 名称和参数以当前 CLI 与对应实现为准：

```bash
harbor run --help
ls src/harbor/agents/installed
```

## 7. 运行任务和数据集

### 7.1 运行单个本地任务

```bash
harbor run -p path/to/task -a oracle
```

例如：

```bash
harbor run -p examples/tasks/hello-world -a oracle
```

### 7.2 运行本地数据集或任务目录

`-p` / `--path` 可以指向本地数据集清单或任务集合：

```bash
harbor run \
  -p path/to/local-dataset \
  -a <agent> \
  -m <model>
```

### 7.3 运行已注册数据集

先查看可用数据集：

```bash
harbor dataset list
```

然后运行：

```bash
harbor run \
  -d "<组织>/<数据集>" \
  -a <agent> \
  -m <model>
```

例如终端类或代码修复类数据集都使用相同方式。省略版本时通常解析为最新版本；如需固定版本，请使用数据集支持的版本或引用格式。

### 7.4 增加尝试次数和并发数

```bash
harbor run \
  -p path/to/tasks \
  -a <agent> \
  -m <model> \
  -k 3 \
  -n 4
```

其中：

- `-k` / `--n-attempts`：每个任务的尝试次数；
- `-n` / `--n-concurrent`：并发 trial 数；
- `--n-concurrent-agents`：限制同时处于 Agent 执行阶段的数量；
- `--max-retries`：异常后的最大重试次数；
- `--timeout-multiplier`：统一调整任务各阶段超时。

请根据本机 CPU、内存、Docker 容量以及 API 限流设置并发数。

### 7.5 选择执行环境

默认使用本地 Docker：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a oracle \
  -e docker
```

云端环境示例：

```bash
export DAYTONA_API_KEY="<your-api-key>"

harbor run \
  -p path/to/tasks \
  -a <agent> \
  -m <model> \
  -e daytona \
  -n 20
```

不同环境可能需要额外依赖、账号、凭据或资源配置。使用前运行：

```bash
harbor run --help
```

并参考 `examples/configs/environments/` 与 `docs/content/docs/` 中对应环境的说明。

## 8. 使用 YAML/JSON 配置运行

参数较多、需要复现实验或同时组合多个 Agent/数据集时，建议使用配置文件。

```bash
harbor run -c examples/configs/agents/claude-code-job.yaml
```

一个简化的配置示例：

```yaml
jobs_dir: jobs
n_attempts: 1
timeout_multiplier: 1.0

orchestrator:
  type: local
  n_concurrent_trials: 2
  quiet: false

environment:
  type: docker
  force_build: false
  delete: true

agents:
  - name: claude-code
    model_name: anthropic/<model-name>

datasets:
  - path: examples/tasks/hello-world
```

检查解析后的完整配置而不启动任务：

```bash
harbor run -c path/to/config.yaml --print-config
```

更多现成配置位于：

- `examples/configs/agents/`：不同 Agent；
- `examples/configs/environments/`：不同执行环境；
- `examples/configs/features/`：产物、模型后端等功能；
- `examples/configs/tests/`：多容器、GPU、网络策略和多步骤任务。

配置结构由 `src/harbor/models/job/config.py` 和 `src/harbor/models/trial/config.py` 中的 Pydantic 模型定义。

## 9. 创建自己的任务

### 9.1 生成任务模板

```bash
harbor task init my-org/my-task
```

生成的典型结构如下：

```text
my-task/
├── instruction.md          # 给 Agent 的任务说明
├── task.toml               # 元数据、超时和资源配置
├── environment/
│   └── Dockerfile          # 任务运行环境
├── solution/
│   └── solve.sh            # 参考解法，可用于 oracle 验证
└── tests/
    ├── test.sh             # 验证入口
    └── test_outputs.py     # 示例测试
```

### 9.2 编写任务

一个任务至少需要明确以下内容：

1. `instruction.md`：Agent 应完成什么；
2. `task.toml`：Agent、验证器和环境的超时与资源；
3. `environment/`：任务依赖和初始环境；
4. `tests/test.sh`：如何验证结果；
5. `solution/`：可选的参考解法。

验证器应将最终奖励写入：

```text
/logs/verifier/reward.txt
```

或者：

```text
/logs/verifier/reward.json
```

### 9.3 手动进入任务环境

```bash
harbor task start-env \
  -p path/to/my-task \
  -e docker \
  -a \
  -i
```

可在容器中手动测试依赖、路径和解题步骤。

### 9.4 用参考解法验证任务

```bash
harbor run -p path/to/my-task -a oracle
```

如果 `oracle` 无法得到预期奖励，应先检查：

- `solution/solve.sh` 是否存在并可执行；
- Dockerfile 是否安装了全部依赖；
- 测试中的路径是否与任务环境一致；
- `tests/test.sh` 是否总能写入奖励文件；
- Agent 和验证器超时是否足够。

可参考 `examples/tasks/` 中的单步骤、多步骤、多容器、MCP 和计算机操作任务。

## 10. 结果目录与分析

默认情况下，每次运行会在 `jobs/` 下创建一个 job：

```text
jobs/<job-name>/
├── config.json             # 实际运行配置
├── result.json             # 整体结果与统计
├── <trial-name>/
│   ├── config.json         # 单次 trial 配置
│   ├── result.json         # 单次 trial 结果
│   ├── agent/              # Agent 日志、轨迹和终端记录
│   └── verifier/           # 奖励、测试输出和验证日志
└── ...
```

常见排查文件包括：

- `result.json`：奖励、耗时和异常信息；
- `agent/trajectory.json`：Agent 执行轨迹；
- `verifier/reward.txt`：最终奖励；
- `verifier/test-stdout.txt`：验证器标准输出；
- `verifier/test-stderr.txt`：验证器错误输出。

通过 `--jobs-dir` 指定其他输出目录：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a oracle \
  --jobs-dir ./output/jobs
```

### 10.1 启动网页查看器

```bash
harbor view ./jobs
```

默认监听 `127.0.0.1`，并从 `8080-8089` 中选择可用端口。也可以指定地址和端口：

```bash
harbor view ./jobs --host 0.0.0.0 --port 8080
```

查看器可用于浏览 job、比较 trial、查看轨迹、奖励、耗时、验证日志和任务产物。

### 10.2 恢复中断的任务

```bash
harbor job resume -p jobs/<job-name>
```

默认会清理特定取消异常对应的 trial 后继续执行。恢复前建议保留原 job 目录，并检查其中的 `config.json` 和失败 trial。

### 10.3 分析轨迹

```bash
harbor analyze jobs/<job-name>
```

可通过下列命令查看当前版本支持的更多选项：

```bash
harbor job --help
harbor trial --help
harbor analyze --help
harbor view --help
```

## 11. 常用 CLI 命令

| 命令 | 用途 |
| --- | --- |
| `harbor run ...` | 启动一个 job，等价于 `harbor job start` |
| `harbor task init ...` | 创建任务模板 |
| `harbor task start-env ...` | 启动并进入任务环境 |
| `harbor dataset list` | 列出可用数据集 |
| `harbor job resume ...` | 恢复中断的 job |
| `harbor view <目录>` | 启动结果查看器 |
| `harbor analyze <job>` | 分析 trial 轨迹 |
| `harbor check ...` | 按质量规则检查任务 |
| `harbor download ...` | 下载任务或数据集 |
| `harbor cache ...` | 管理本地缓存 |
| `harbor --version` | 显示版本 |
| `harbor --help` | 显示顶层命令帮助 |

CLI 当前以单数命令组为主，例如 `task`、`dataset`、`job` 和 `trial`。旧的复数形式可能仍作为隐藏兼容别名存在，但新脚本应使用单数形式。

## 12. 开发与验证

### 12.1 安装开发依赖

```bash
uv sync --all-extras --dev
```

### 12.2 运行单元测试

日常改动默认只运行单元测试：

```bash
uv run pytest tests/unit/
```

只有改动明确涉及集成逻辑或运行时环境时，再按需运行：

```bash
uv run pytest tests/integration/
uv run pytest -m runtime
```

部分运行时测试需要 Docker 或外部服务。

### 12.3 代码格式、Lint 和类型检查

修改代码后依次执行：

```bash
uv run ruff check --fix .
uv run ruff format .
uv run ty check
```

### 12.4 开发结果查看器

查看器位于 `apps/viewer/`，使用 Bun：

```bash
cd apps/viewer
bun install
bun run dev
```

也可以让 CLI 以开发模式启动：

```bash
harbor view ./jobs --dev
```

### 12.5 开发文档网站

文档站位于 `docs/`：

```bash
cd docs
bun install
bun dev
```

## 13. 常见问题

### Docker 无法连接

确认 daemon 已启动，并检查：

```bash
docker info
```

Linux 下还要确认当前用户具有 Docker 权限。

### 模型鉴权失败

- 确认服务商 API Key 已导出；
- 确认变量通过 `--ae`、`--env-file` 或配置文件传入正确阶段；
- 确认模型名与 Agent 支持的格式一致；
- 使用 `--print-config` 检查解析结果，但不要公开包含密钥的输出。

### 任务一直超时

- 检查 `task.toml` 中的 Agent、验证器和环境构建超时；
- 临时增加 `--timeout-multiplier`；
- 检查 Docker 构建、软件源或模型 API 是否卡住；
- 查看 trial 的 `result.json` 和日志文件。

### 并发运行不稳定

降低 `--n-concurrent`，并检查：

- 本机 CPU、内存和磁盘空间；
- Docker 并发构建能力；
- 模型服务商速率限制；
- 云环境配额；
- 是否需要设置 `--n-concurrent-agents`。

### 验证器没有奖励

确保 `tests/test.sh` 无论成功或失败都能写入 `/logs/verifier/reward.txt` 或 `/logs/verifier/reward.json`，并检查验证器的 stdout、stderr 和退出状态。

### 配置文件无法解析

先执行：

```bash
harbor run -c path/to/config.yaml --print-config
```

然后对照：

- `examples/configs/` 中的当前示例；
- `src/harbor/models/job/config.py`；
- `src/harbor/models/trial/config.py`；
- 当前配置模型和仓库内文档中的迁移说明。

## 14. 获取进一步帮助

优先使用当前安装版本自带的帮助，以避免文档和版本不一致：

```bash
harbor --help
harbor run --help
harbor task --help
harbor dataset --help
harbor job --help
harbor trial --help
harbor view --help
```

进一步资料：

- 仓库内文档：[`docs/content/docs/`](docs/content/docs/)
- 示例任务：[`examples/tasks/`](examples/tasks/)
- 示例配置：[`examples/configs/`](examples/configs/)
- 配置模型：[`src/harbor/models/`](src/harbor/models/)
- 在线文档：<https://harborframework.com/docs>

## 15. 许可证

本项目采用 Apache-2.0 许可证，详见 [`LICENSE`](LICENSE)。
