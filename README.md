# Codex Continuous Framework

Codex Continuous Framework 是一个轻量级 Shell 封装，用来在隔离服务器上持续运行已经安装好的 `codex` CLI，让 Codex 按文档进行无人值守的自动开发迭代。

它不会修改 Codex 自身。框架只负责给 Codex 提供目标项目目录、当前迭代文档、运行状态目录，以及一份提示词约定，让 Codex 完成一个小阶段、写出下一轮文档，然后继续执行。

默认策略是进取式自主迭代：当第一版用户需求完成后，Codex 会主动做全面验证，分析项目还有哪些值得开发的新功能，生成新的功能迭代文档，并继续进入实现，而不是只做字段命名、格式调整或零散小重构。

## 目录结构

```text
codex-continuous-framework/
  bin/
    codex-continuous-runner.sh   # 主循环脚本
  config/
    runner.env.example           # 常规配置模板
    runner.unrestricted.env.example
  docs/
    context/                     # 每轮固定注入的长期上下文，除 .gitkeep 外不入库
    iterations/                  # 生成的迭代文档，除 .gitkeep 外不入库
    templates/                   # 入库的初始迭代文档模板
  projects/                      # 被持续开发的项目，除 .gitkeep 外不入库
  runs/                          # 运行时提示词、日志和状态，除 .gitkeep 外不入库
```

`projects/`、`runs/`、`docs/iterations/` 和 `docs/context/` 在 git 中故意保持为空目录。它们是服务器上的工作目录，可能包含被拉取的项目、大量生成产物、日志、工具链、提示词、迭代文档和项目长期上下文。

## 快速开始

把要持续迭代的项目放到 `projects/` 下：

```bash
cd codex-continuous-framework
git clone <repo-url> projects/my-app
```

创建第一份迭代文档：

```bash
cp docs/templates/seed-template.md docs/iterations/my-app-seed.md
```

如果有一份需求或原则需要每一轮都对 Codex 可见，放到长期上下文目录：

```bash
mkdir -p docs/context
cp my-app-long-term-context.md docs/context/
```

持续运行：

```bash
CODEX_MAX_ROUNDS=0 \
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

在 Ubuntu 上用 `tmux` 运行：

```bash
tmux new -s codex-my-app
cd /path/to/codex-continuous-framework
source config/runner.env
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

按 `Ctrl-b d` 断开 `tmux` 会话。重新连接：

```bash
tmux attach -t codex-my-app
```

## 最大权限沙箱模式

如果 Ubuntu 服务器本身就是可丢弃的隔离沙箱，可以使用最大权限配置：

```bash
cp config/runner.unrestricted.env.example config/runner.env
source config/runner.env
./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

这个模式会用下面的方式运行 Codex：

```bash
codex --search exec --dangerously-bypass-approvals-and-sandbox ...
```

同时，runner 会在提示词中授权 Codex：

- 执行 `sudo` 命令
- 访问网页、搜索资料和使用网络
- 安装依赖和系统包
- 编写并运行辅助脚本
- 启动 dev server 或后台服务
- 监控端口、健康检查、日志和进程状态

只应在可丢弃的虚拟机、容器或其他外部隔离环境中使用这个模式。

## 运行状态

以项目 `my-app` 为例，runner 会写入：

```text
runs/my-app/
  control/
    next-requirements.md          # 可选，一次性的下一轮需求
    stop-after-current-round      # 可选，本轮结束后停止的标记
  logs/       # codex --json 输出和最后一条 assistant 消息
  prompts/    # 每轮发送给 Codex 的提示词
  requests/   # 可选，下一轮要追加读取的 *.md 或 *.txt 需求文件
    processed/
  state/
    current_doc
    round
    session_started
```

Codex 必须把下一轮要读取的迭代文档路径写入：

```text
runs/my-app/state/current_doc
```

`current_doc` 中的相对路径会基于 `docs/iterations/` 解析。

## 长期常驻上下文

`docs/iterations/` 里的文档代表“当前这一轮或下一轮要执行的任务”。如果某些信息应该长期存在，例如产品方向、不可破坏的规则、测试素材路径、视觉标准、用户偏好、项目约束，就放在：

```text
docs/context/
```

runner 每轮都会把 `docs/context/*.md` 和 `docs/context/*.txt` 注入 Codex 提示词。这些文件不会被消费或移动，适合多轮持续可见。

也可以用环境变量指定额外文件，多个路径用冒号分隔：

```bash
export CODEX_CONTEXT_FILES=/srv/shared/product-principles.md:/srv/shared/test-fixtures.md
```

默认情况下，`docs/context/` 中除 `.gitkeep` 外的文件不会进入框架仓库。这样可以把项目专属长期要求保留在服务器上，同时保持框架仓库干净可迁移。

## 目标项目内的 Git 行为

框架本身不会对目标项目执行 `git checkout`、`git commit` 或 `git push`。这些动作都交给 Codex 自己在目标项目里判断和执行。runner 只会在每轮提示词中加入 git 约定：

- 修改项目代码前，先检查 `git status` 和当前分支
- 每轮基于当前 `HEAD` 创建一个专用迭代分支
- 只有在已经处于本轮分支，或存在未提交改动导致切换不安全时，才继续使用当前分支
- 每次提交只包含一个已经验证通过的阶段性改动
- 每完成一个完整阶段并验证通过后，尝试提交
- 除非当前迭代文档明确要求，否则不要 push
- 避免破坏性 git 操作，例如 `reset --hard`、`clean`、强推或删除未知改动

这样可以把分支和提交决策留在 Codex 的正常推理流程里，而不是把仓库操作硬编码进 runner。

## 自主迭代策略

runner 默认使用 `CODEX_STRATEGY_MODE=expansive`。这个模式会要求 Codex：

- 当前迭代文档完成后，主动进入新功能发现，而不是停在小修小补
- 尽量运行项目的完整测试、构建、lint、类型检查、smoke test 或服务健康检查
- 如果完整验证太慢或环境不支持，运行最大可行子集，并把跳过原因写入文档
- 基于项目目标、README、现有命令、用户工作流、测试缺口、可观测性、配置体验、部署体验等来源，提出 2 到 4 个新功能候选
- 选择一个用户价值或工程价值最高、风险可控的新功能，创建 `feature-<round>-<slug>.md`
- 新功能文档必须包含目标、用户价值、范围、实现切片、验证矩阵、git 分支和提交计划、回滚方式、风险
- 如果本轮时间足够，可以在写完新功能文档后直接开始第一个实现切片

这套策略的核心假设是：每轮都有独立 git 分支和阶段性提交，因此可以更大胆地探索新功能。失败的尝试应该被文档化，并由后续轮次缩小范围、回滚或重新选择方向。

如果某个项目只适合保守维护，可以设置：

```bash
export CODEX_STRATEGY_MODE=conservative
```

如果暂时不希望 Codex 主动规划新功能：

```bash
export CODEX_FEATURE_DISCOVERY=0
```

如果完整测试非常昂贵，也可以关闭强制基线验证提示：

```bash
export CODEX_BASELINE_VERIFY=0
```

## 运行中控制

### 当前轮结束后停止

runner 正在运行时，创建这个文件：

```bash
touch runs/my-app/control/stop-after-current-round
```

runner 不会中断正在执行的 Codex 进程。它会等待当前轮正常结束，写完日志和状态，然后在下一轮开始前退出。

再次启动前，删除这个标记文件：

```bash
rm -f runs/my-app/control/stop-after-current-round
```

### 给下一轮追加需求

如果只追加一份一次性需求，写入：

```bash
cat > runs/my-app/control/next-requirements.md <<'EOF'
下一轮优先优化 smoke test 的速度，但不要改变现有行为。
EOF
```

如果要追加多份需求文件：

```bash
mkdir -p runs/my-app/requests
cp urgent-followup.md runs/my-app/requests/
```

下一轮开始前，runner 会把 `next-requirements.md` 以及所有顶层的 `runs/my-app/requests/*.md` 或 `*.txt` 文件注入 Codex 提示词。这些追加需求的优先级高于上一轮生成的后续方向。默认情况下，一轮成功结束后，这些已注入的需求文件会被移动到 `runs/my-app/requests/processed/`。

如果某个需求不是一次性的，而是希望后续每一轮都持续可见，不要放到 `requests/`，应该放到 `docs/context/`。

## 重要环境变量

| 变量 | 含义 |
| --- | --- |
| `CODEX_BIN` | Codex 可执行文件，默认 `codex`。 |
| `CODEX_MODEL` | 可选，通过 `-m` 传给 Codex 的模型名。 |
| `CODEX_PROFILE` | 可选，通过 `-p` 传给 Codex 的配置 profile。 |
| `CODEX_PROJECTS_DIR` | 项目根目录，默认 `projects/`。 |
| `CODEX_DOCS_DIR` | 迭代文档目录，默认 `docs/iterations/`。 |
| `CODEX_CONTEXT_DOCS_DIR` | 长期常驻上下文目录，默认 `docs/context/`。 |
| `CODEX_CONTEXT_FILES` | 额外长期上下文文件，多个路径用冒号分隔。 |
| `CODEX_RUNS_DIR` | 运行状态目录，默认 `runs/`。 |
| `CODEX_RUN_NAME` | 覆盖本次运行目录名。 |
| `CODEX_MAX_ROUNDS` | 最大轮数，`0` 表示一直运行。 |
| `CODEX_SLEEP_SECONDS` | 每轮之间的等待秒数。 |
| `CODEX_RESET_LOOP` | 设为 `1` 时忽略已保存状态，从 seed 文档重新开始。 |
| `CODEX_STRATEGY_MODE` | 迭代策略，默认 `expansive`。可设为 `conservative`。 |
| `CODEX_BASELINE_VERIFY` | 是否要求 Codex 主动做全面基线验证，默认 `1`。 |
| `CODEX_FEATURE_DISCOVERY` | 是否要求 Codex 主动发现并规划新功能，默认 `1`。 |
| `CODEX_STOP_AFTER_CURRENT_ROUND_FILE` | 覆盖“本轮结束后停止”标记文件路径。 |
| `CODEX_NEXT_REQUIREMENTS_FILE` | 覆盖一次性下一轮需求文件路径。 |
| `CODEX_REQUESTS_DIR` | 覆盖下一轮需求文件目录。 |
| `CODEX_CONSUME_REQUIREMENTS` | 成功注入后移动需求文件，默认 `1`。 |
| `CODEX_UNRESTRICTED` | 设为 `1` 时启用隔离服务器最大权限模式。 |
| `CODEX_DANGER_FULL_ACCESS` | 给 Codex 传入 `--dangerously-bypass-approvals-and-sandbox`。 |
| `CODEX_ENABLE_SEARCH` | 给 Codex 传入顶层 `--search`。 |
| `CODEX_ALLOW_SUDO` | 在提示词约定中告诉 Codex 可以使用 sudo。 |
| `CODEX_ALLOW_INSTALL` | 在提示词约定中告诉 Codex 可以安装依赖和系统包。 |
| `CODEX_ALLOW_LONG_RUNNING` | 在提示词约定中告诉 Codex 可以启动后台服务或长时间运行进程。 |
| `CODEX_ALLOW_SCRIPTING` | 在提示词约定中告诉 Codex 可以编写并运行辅助脚本。 |

如果想忽略已保存的 runner 状态，从 seed 文档重新开始：

```bash
CODEX_RESET_LOOP=1 ./bin/codex-continuous-runner.sh my-app my-app-seed.md
```

## Git 管理规则

本仓库只跟踪自动化框架本身：

- `bin/`
- `config/*.example`
- `docs/templates/`
- `docs/context/`、`docs/iterations/`、`projects/` 和 `runs/` 的空目录占位文件

下面这些内容会被故意忽略：

- `projects/` 下被拉取或被持续开发的项目
- `docs/iterations/` 下生成的迭代文档
- `docs/context/` 下的项目长期上下文文档
- `runs/` 下的提示词、日志、状态、脚本、监控文件、工具链和缓存
- 本地操作配置，例如 `config/runner.env`

这样可以让框架仓库保持可迁移，也能避免运行中的自动化会话污染框架自身的 git 历史。
