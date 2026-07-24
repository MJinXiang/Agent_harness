# Agent 评测与运行框架使用说明

本仓库提供一套用于运行、评测和分析 Claude Code Agent Harness 的完整工具链。它可以把任务放入隔离环境中交给 Claude Code 执行，运行自动验证器，并将每次执行的轨迹、日志、奖励和异常统一保存下来。

本文档以“如何使用当前仓库”为主，覆盖环境准备、安装、首次运行、任务编写、批量配置、结果查看、开发测试和常见问题。

## 1. 适用场景

你可以使用本仓库完成以下工作：

- 在 Docker 或云端沙箱中运行 Claude Code；
- 对同一批任务测试不同 Claude 模型和 Claude Code 参数；
- 运行本地任务、公开数据集或自定义数据集；
- 并发执行多次尝试，并自动汇总通过率和奖励；
- 保存 Agent 轨迹、终端记录、验证器日志和产物；
- 创建自己的任务、环境和验证规则；
- 通过网页查看器分析任务结果和失败原因；
- 为强化学习或其他训练流程生成 rollout 数据。

### 1.1 Claude Code Harness 接入范围

本文档只介绍 Claude Code。运行时固定使用：

```bash
-a claude-code
```

当前接入实现位于 [`src/harbor/agents/installed/claude_code.py`](src/harbor/agents/installed/claude_code.py)，已经覆盖：

- 在每个隔离环境内检查并按需安装 Claude Code；
- 通过 API Key、OAuth Token 或 Amazon Bedrock 完成认证；
- 将所选 Claude 模型传给 Claude Code；
- 使用 Claude Code 非交互模式执行任务指令；
- 收集完整命令输出、会话文件和工具调用轨迹；
- 将轨迹转换为 ATIF 格式，供结果查看器和分析流程使用；
- 支持多步骤任务中的 Claude Code 会话恢复；
- 支持 MCP、Skills、权限模式、轮数、推理强度和预算等参数。

最基本的调用格式是：

```bash
harbor run \
  -p <任务或数据集路径> \
  -a claude-code \
  -m anthropic/<Claude模型名称>
```

主机上是否已经安装 `claude` 不影响容器内的安装流程：适配器会在任务环境中独立检查和安装 Claude Code，以保证评测环境可复现。

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
│   ├── configs/agents/  # Claude Code Job 配置示例
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

## 5. 第一次运行 Claude Code

### 5.1 配置认证

批量评测推荐使用 Anthropic API Key：

```bash
export ANTHROPIC_API_KEY="<your-api-key>"
```

不要把密钥写入配置文件、README 或提交到 Git。

### 5.2 运行仓库自带任务

从当前源码仓库运行：

```bash
uv run harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

如果已经安装发行版，可以去掉 `uv run`：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

执行过程包括：

1. 读取任务配置与指令；
2. 构建或启动隔离环境；
3. 在隔离环境内检查并安装 Claude Code；
4. 将指令通过 `claude --print` 非交互模式交给 Claude Code；
5. 执行任务验证器；
6. 保存 Claude Code 日志、轨迹、奖励和异常；
7. 按配置停止或删除环境。

默认结果写入 `jobs/`。

## 6. Claude Code 接入与配置

### 6.1 API Key 认证（推荐）

适合 CI、服务器和批量评测：

```bash
export ANTHROPIC_API_KEY="<your-api-key>"

harbor run \
  -p <任务或本地数据集路径> \
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

适配器会把密钥传入 Claude Code 所在的隔离环境。也可以通过 `.env` 文件加载：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  --env-file .env
```

### 6.2 Claude Code OAuth/订阅认证

如果要使用 Claude Code 的 OAuth 或订阅 Token，先在可信环境执行：

```bash
claude setup-token
```

然后设置：

```bash
export CLAUDE_CODE_OAUTH_TOKEN="<your-token>"
export CLAUDE_FORCE_OAUTH=1
```

再正常运行：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

`CLAUDE_FORCE_OAUTH=1` 会让适配器忽略 API Key 并强制使用 OAuth Token。如果设置了该变量但没有设置 `CLAUDE_CODE_OAUTH_TOKEN`，任务会在启动阶段报错。

### 6.3 Amazon Bedrock 认证

启用 Bedrock：

```bash
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=us-east-1
```

然后使用标准 AWS 凭据链，例如：

```bash
export AWS_ACCESS_KEY_ID="<access-key>"
export AWS_SECRET_ACCESS_KEY="<secret-key>"
export AWS_SESSION_TOKEN="<session-token>"  # 临时凭据需要
```

也可以使用 `AWS_PROFILE` 或 `AWS_BEARER_TOKEN_BEDROCK`。运行时把 Bedrock 模型 ID 原样传给 `-m`：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m '<Bedrock模型ID>'
```

### 6.4 模型配置

使用 Anthropic 官方 API 时，建议写成 `anthropic/<model-id>`。适配器会在调用 Claude Code 前去掉 `anthropic/` 前缀：

```bash
-m anthropic/claude-opus-4-8
```

也可以通过主机环境变量提供默认模型：

```bash
export ANTHROPIC_MODEL=claude-opus-4-8
```

显式传入 `-m` 更有利于实验复现。不要继续使用仓库旧示例中可能出现的已退休模型名称。

### 6.5 Claude Code 参数

通过可重复的 `--ak key=value` 配置 Claude Code：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  --ak max_turns=30 \
  --ak reasoning_effort=high \
  --ak max_budget_usd=5
```

支持的主要参数：

| 参数 | 作用 |
| --- | --- |
| `max_turns` | 限制 Claude Code 最大交互轮数 |
| `reasoning_effort` | 推理强度：`low`、`medium`、`high`、`xhigh`、`max` 或 `ultracode` |
| `max_budget_usd` | 限制单次运行的最高美元预算 |
| `fallback_model` | 主模型不可用时使用的后备模型 |
| `append_system_prompt` | 追加 Claude Code 系统提示 |
| `allowed_tools` | 限制允许调用的工具 |
| `disallowed_tools` | 禁止指定工具 |
| `permission_mode` | Claude Code 权限模式，隔离评测默认使用 `bypassPermissions` |

还可以通过环境变量设置部分参数：

```bash
export CLAUDE_CODE_MAX_TURNS=30
export CLAUDE_CODE_EFFORT_LEVEL=high
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
```

### 6.6 向 Claude Code 传递额外环境变量

使用 `--ae` / `--agent-env`：

```bash
harbor run \
  -p examples/tasks/hello-world \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  --ae AWS_REGION=us-east-1 \
  --ae CUSTOM_VARIABLE=value
```

该参数可以重复使用。运行前可检查最终解析配置：

```bash
harbor run -c path/to/config.yaml --print-config
```

### 6.7 MCP、Skills 和会话恢复

Claude Code 适配器可以接收 MCP 配置和 Skills：

```bash
harbor run \
  -p path/to/task \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  --mcp-config .mcp.json \
  --skill path/to/skill
```

多步骤任务可使用 Claude Code 原生会话恢复：

```bash
harbor run \
  -p path/to/multi-step-task \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  --resume-trajectory
```

详细参数以当前版本为准：

```bash
harbor run --help
```

## 7. 运行任务和数据集

### 7.1 运行单个本地任务

```bash
harbor run -p path/to/task -a claude-code \
  -m anthropic/claude-opus-4-8
```

例如：

```bash
harbor run -p examples/tasks/hello-world -a claude-code \
  -m anthropic/claude-opus-4-8
```

### 7.2 运行本地数据集或任务目录

`-p` / `--path` 可以指向本地数据集清单或任务集合：

```bash
harbor run \
  -p path/to/local-dataset \
  -a claude-code \
  -m anthropic/claude-opus-4-8
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
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

例如终端类或代码修复类数据集都使用相同方式。省略版本时通常解析为最新版本；如需固定版本，请使用数据集支持的版本或引用格式。

### 7.4 增加尝试次数和并发数

```bash
harbor run \
  -p path/to/tasks \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
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
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  -e docker
```

云端环境示例：

```bash
export DAYTONA_API_KEY="<your-api-key>"

harbor run \
  -p path/to/tasks \
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
  -e daytona \
  -n 20
```

不同环境可能需要额外依赖、账号、凭据或资源配置。使用前运行：

```bash
harbor run --help
```

并参考 `examples/configs/environments/` 与 `docs/content/docs/` 中对应环境的说明。

## 8. 使用 YAML/JSON 配置运行

参数较多、需要复现 Claude Code 实验或运行多个数据集时，建议使用配置文件。

先参考 `examples/configs/agents/claude-code-job.yaml` 创建自己的配置，并将其中模型名更新为当前可用模型，然后运行：

```bash
harbor run -c path/to/claude-code-job.yaml
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
    model_name: anthropic/claude-opus-4-8
    kwargs:
      max_turns: 30
      reasoning_effort: high
      max_budget_usd: "5"

datasets:
  - path: examples/tasks/hello-world
```

检查解析后的完整配置而不启动任务：

```bash
harbor run -c path/to/config.yaml --print-config
```

更多现成配置位于：

- `examples/configs/agents/claude-code-job.yaml`：Claude Code Job 配置；
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
│   └── solve.sh            # 可选参考解法，用于人工核对任务
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

### 9.4 用 Claude Code 验证任务

```bash
harbor run \
  -p path/to/my-task \
  -a claude-code \
  -m anthropic/claude-opus-4-8
```

如果 Claude Code 完成了任务但没有得到预期奖励，应检查：

- Dockerfile 是否安装了全部依赖；
- 测试中的路径是否与任务环境一致；
- `tests/test.sh` 是否总能写入奖励文件；
- Claude Code 和验证器超时是否足够；
- `jobs/<job-name>/<trial-name>/agent/claude-code.txt` 中是否有认证或执行错误。

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
  -a claude-code \
  -m anthropic/claude-opus-4-8 \
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
