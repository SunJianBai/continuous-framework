#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
用法：
  codex-continuous-runner.sh <project-name-or-abs-path> <seed-doc>

示例：
  CODEX_MAX_ROUNDS=0 ./bin/codex-continuous-runner.sh my-app seed-my-app.md
  CODEX_MAX_ROUNDS=0 ./bin/codex-continuous-runner.sh /srv/my-app seed-my-app.md

环境变量：
  CODEX_BIN                         Codex 可执行文件，默认：codex
  CODEX_MODEL                       可选，通过 -m 传给 Codex 的模型名
  CODEX_PROFILE                     可选，通过 -p 传给 Codex 的配置 profile
  CODEX_PROJECTS_DIR                项目根目录，默认：<framework>/projects
  CODEX_DOCS_DIR                    迭代文档目录，默认：<framework>/docs/iterations
  CODEX_CONTEXT_DOCS_DIR            每轮固定注入的长期上下文目录，默认：<framework>/docs/context
  CODEX_CONTEXT_FILES               额外长期上下文文件，多个路径用冒号分隔
  CODEX_RUNS_DIR                    运行状态和日志目录，默认：<framework>/runs
  CODEX_RUN_NAME                    覆盖运行目录名，默认使用清理后的项目目录名
  CODEX_UNRESTRICTED                设为 1 时启用隔离服务器最大权限模式
  CODEX_RUNNER_SANDBOX              read-only | workspace-write | danger-full-access，默认：workspace-write
  CODEX_FULL_AUTO                   设为 1 时使用 --full-auto，而不是显式 sandbox 配置
  CODEX_DANGER_FULL_ACCESS          设为 1 时使用 --dangerously-bypass-approvals-and-sandbox
  CODEX_ENABLE_SEARCH               设为 1 时传入顶层 --search
  CODEX_ALLOW_SUDO                  设为 1 时在提示词中告诉 Codex 可以使用 sudo
  CODEX_ALLOW_INSTALL               设为 1 时在提示词中告诉 Codex 可以安装依赖和系统包
  CODEX_ALLOW_LONG_RUNNING          设为 1 时在提示词中告诉 Codex 可以启动长时间运行服务
  CODEX_ALLOW_SCRIPTING             设为 1 时在提示词中告诉 Codex 可以编写和运行辅助脚本
  CODEX_MAX_ROUNDS                  0 表示一直运行，默认：0
  CODEX_SLEEP_SECONDS               每轮之间的暂停秒数，默认：10
  CODEX_MAX_CONSECUTIVE_FAILURES    连续失败达到该次数后停止，默认：3
  CODEX_STRATEGY_MODE               迭代策略：expansive | conservative，默认：expansive
  CODEX_BASELINE_VERIFY             设为 1 时要求主动做全面基线验证，默认：1
  CODEX_FEATURE_DISCOVERY           设为 1 时要求主动发现并规划新功能，默认：1
  CODEX_EXTRA_ARGS                  原样追加到 codex exec 的额外参数
  CODEX_RESET_LOOP                  设为 1 时忽略已保存状态
  CODEX_STOP_AFTER_CURRENT_ROUND_FILE
                                    控制文件。存在时，在当前轮结束后停止
  CODEX_NEXT_REQUIREMENTS_FILE       一次性的下一轮追加需求文件
  CODEX_REQUESTS_DIR                 放入 *.md 或 *.txt 文件，用于注入下一轮需求
  CODEX_CONSUME_REQUIREMENTS         成功轮次后移动已注入需求文件，默认：1
  CODEX_RESET_SESSION                设为 1 时丢弃保存的 Codex 会话 id，重新开始会话
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 2 ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CODEX_BIN="${CODEX_BIN:-codex}"
PROJECT_ARG="$1"
SEED_DOC="$2"
MAX_ROUNDS="${CODEX_MAX_ROUNDS:-0}"
SLEEP_SECONDS="${CODEX_SLEEP_SECONDS:-10}"
MAX_CONSECUTIVE_FAILURES="${CODEX_MAX_CONSECUTIVE_FAILURES:-3}"
STRATEGY_MODE="${CODEX_STRATEGY_MODE:-expansive}"
BASELINE_VERIFY="${CODEX_BASELINE_VERIFY:-1}"
FEATURE_DISCOVERY="${CODEX_FEATURE_DISCOVERY:-1}"
RUNNER_SANDBOX="${CODEX_RUNNER_SANDBOX:-workspace-write}"
PROJECTS_DIR="${CODEX_PROJECTS_DIR:-$FRAMEWORK_ROOT/projects}"
DOCS_DIR="${CODEX_DOCS_DIR:-$FRAMEWORK_ROOT/docs/iterations}"
CONTEXT_DOCS_DIR="${CODEX_CONTEXT_DOCS_DIR:-$FRAMEWORK_ROOT/docs/context}"
RUNS_DIR="${CODEX_RUNS_DIR:-$FRAMEWORK_ROOT/runs}"
UNRESTRICTED="${CODEX_UNRESTRICTED:-0}"
DANGER_FULL_ACCESS="${CODEX_DANGER_FULL_ACCESS:-0}"
ENABLE_SEARCH="${CODEX_ENABLE_SEARCH:-0}"
ALLOW_SUDO="${CODEX_ALLOW_SUDO:-0}"
ALLOW_INSTALL="${CODEX_ALLOW_INSTALL:-0}"
ALLOW_LONG_RUNNING="${CODEX_ALLOW_LONG_RUNNING:-0}"
ALLOW_SCRIPTING="${CODEX_ALLOW_SCRIPTING:-1}"

if [[ "$UNRESTRICTED" == "1" ]]; then
  DANGER_FULL_ACCESS=1
  ENABLE_SEARCH=1
  ALLOW_SUDO=1
  ALLOW_INSTALL=1
  ALLOW_LONG_RUNNING=1
  ALLOW_SCRIPTING=1
fi

mkdir -p "$PROJECTS_DIR" "$DOCS_DIR" "$CONTEXT_DOCS_DIR" "$RUNS_DIR"

if [[ "$PROJECT_ARG" = /* ]]; then
  PROJECT_DIR="$PROJECT_ARG"
else
  PROJECT_DIR="$PROJECTS_DIR/$PROJECT_ARG"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "项目目录不存在：$PROJECT_DIR"
  echo "请把项目放到 $PROJECTS_DIR 下，或传入绝对项目路径。"
  exit 2
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
DOCS_DIR="$(cd "$DOCS_DIR" && pwd)"
CONTEXT_DOCS_DIR="$(cd "$CONTEXT_DOCS_DIR" && pwd)"
RUNS_DIR="$(cd "$RUNS_DIR" && pwd)"

project_base="$(basename "$PROJECT_DIR")"
if [[ -n "${CODEX_RUN_NAME:-}" ]]; then
  project_key="$CODEX_RUN_NAME"
else
  project_key="$(printf '%s' "$project_base" | tr -cs '[:alnum:]_.-' '-')"
  project_key="${project_key%-}"
fi

LOOP_DIR="$RUNS_DIR/$project_key"
LOG_DIR="$LOOP_DIR/logs"
PROMPT_DIR="$LOOP_DIR/prompts"
SCRIPT_WORK_DIR="$LOOP_DIR/scripts"
MONITOR_DIR="$LOOP_DIR/monitors"
STATE_DIR="$LOOP_DIR/state"
CONTROL_DIR="$LOOP_DIR/control"
REQUESTS_DIR="${CODEX_REQUESTS_DIR:-$LOOP_DIR/requests}"
PROCESSED_REQUESTS_DIR="$REQUESTS_DIR/processed"
mkdir -p "$LOG_DIR" "$PROMPT_DIR" "$SCRIPT_WORK_DIR" "$MONITOR_DIR" "$STATE_DIR" "$CONTROL_DIR" "$REQUESTS_DIR" "$PROCESSED_REQUESTS_DIR"

resolve_doc_path() {
  local doc="$1"
  if [[ "$doc" = /* ]]; then
    printf '%s\n' "$doc"
  else
    printf '%s\n' "$DOCS_DIR/$doc"
  fi
}

STATE_CURRENT_DOC="$STATE_DIR/current_doc"
STATE_SESSION_STARTED="$STATE_DIR/session_started"
STATE_SESSION_ID="$STATE_DIR/session_id"
STATE_ROUND="$STATE_DIR/round"
STOP_AFTER_CURRENT_ROUND_FILE="${CODEX_STOP_AFTER_CURRENT_ROUND_FILE:-$CONTROL_DIR/stop-after-current-round}"
NEXT_REQUIREMENTS_FILE="${CODEX_NEXT_REQUIREMENTS_FILE:-$CONTROL_DIR/next-requirements.md}"
CONSUME_REQUIREMENTS="${CODEX_CONSUME_REQUIREMENTS:-1}"
CURRENT_DOC="$(resolve_doc_path "$SEED_DOC")"

if [[ "${CODEX_RESET_LOOP:-0}" == "1" || ! -s "$STATE_CURRENT_DOC" ]]; then
  printf '%s\n' "$CURRENT_DOC" > "$STATE_CURRENT_DOC"
fi

if [[ "${CODEX_RESET_LOOP:-0}" == "1" ]]; then
  : > "$STATE_SESSION_STARTED"
  rm -f "$STATE_SESSION_ID"
  printf '0\n' > "$STATE_ROUND"
fi

if [[ "${CODEX_RESET_SESSION:-0}" == "1" ]]; then
  : > "$STATE_SESSION_STARTED"
  rm -f "$STATE_SESSION_ID"
fi

if [[ -s "$STATE_ROUND" ]] && [[ "$(head -n 1 "$STATE_ROUND")" =~ ^[0-9]+$ ]]; then
  round=$(( $(head -n 1 "$STATE_ROUND") + 1 ))
else
  round=1
fi
consecutive_failures=0
additional_requirement_sources=()
persistent_context_sources=()

collect_persistent_context() {
  local output_file="$1"
  persistent_context_sources=()
  : > "$output_file"

  while IFS= read -r context_file; do
    [[ -n "$context_file" ]] || continue
    persistent_context_sources+=("$context_file")
  done < <(find "$CONTEXT_DOCS_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) -print | sort)

  if [[ -n "${CODEX_CONTEXT_FILES:-}" ]]; then
    local explicit_context_files
    local context_file
    IFS=':' read -r -a explicit_context_files <<< "$CODEX_CONTEXT_FILES"
    for context_file in "${explicit_context_files[@]}"; do
      [[ -n "$context_file" ]] || continue
      if [[ -f "$context_file" ]]; then
        persistent_context_sources+=("$context_file")
      else
        echo "警告：CODEX_CONTEXT_FILES 指向不存在的文件：$context_file" >&2
      fi
    done
  fi

  if [[ "${#persistent_context_sources[@]}" -eq 0 ]]; then
    return 1
  fi

  {
    echo "长期常驻上下文："
    echo
    echo "下面这些文档由 runner 每轮固定注入。它们不会像一次性追加需求那样被消费，适合保存长期目标、项目原则、测试素材路径、风格标准和持续策略。"
    echo
    for context_file in "${persistent_context_sources[@]}"; do
      echo "===== $context_file ====="
      cat "$context_file"
      echo
    done
  } > "$output_file"
}

collect_additional_requirements() {
  local output_file="$1"
  additional_requirement_sources=()
  : > "$output_file"

  if [[ -s "$NEXT_REQUIREMENTS_FILE" ]]; then
    additional_requirement_sources+=("$NEXT_REQUIREMENTS_FILE")
  fi

  while IFS= read -r request_file; do
    [[ -n "$request_file" ]] || continue
    additional_requirement_sources+=("$request_file")
  done < <(find "$REQUESTS_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) -print | sort)

  if [[ "${#additional_requirement_sources[@]}" -eq 0 ]]; then
    return 1
  fi

  {
    echo "运行中追加的下一轮需求："
    echo
    echo "下面这些文件由 runner 在本轮开始前收集。它们的优先级高于上一轮生成的后续方向；如果与当前迭代文档冲突，以这些新增需求为准。"
    echo
    for request_file in "${additional_requirement_sources[@]}"; do
      echo "===== $request_file ====="
      cat "$request_file"
      echo
    done
  } > "$output_file"
}

archive_consumed_requirements() {
  [[ "$CONSUME_REQUIREMENTS" == "1" ]] || return 0
  [[ "${#additional_requirement_sources[@]}" -gt 0 ]] || return 0

  mkdir -p "$PROCESSED_REQUESTS_DIR"
  local request_file
  local request_base
  for request_file in "${additional_requirement_sources[@]}"; do
    [[ -f "$request_file" ]] || continue
    request_base="$(basename "$request_file")"
    mv "$request_file" "$PROCESSED_REQUESTS_DIR/${stamp}-${request_base}"
  done
}

extract_session_id_from_log() {
  local log_file="$1"
  local thread_line
  thread_line="$(grep -m 1 '"thread.started"' "$log_file" || true)"
  [[ -n "$thread_line" ]] || return 1
  printf '%s\n' "$thread_line" | sed -nE 's/.*"thread_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}

while true; do
  if [[ -f "$STOP_AFTER_CURRENT_ROUND_FILE" ]]; then
    echo "检测到停止标记，未启动 round=$round：$STOP_AFTER_CURRENT_ROUND_FILE"
    exit 0
  fi

  if [[ "$MAX_ROUNDS" != "0" && "$round" -gt "$MAX_ROUNDS" ]]; then
    echo "已达到 CODEX_MAX_ROUNDS=$MAX_ROUNDS"
    exit 0
  fi

  if [[ -s "$STATE_CURRENT_DOC" ]]; then
    next_doc="$(head -n 1 "$STATE_CURRENT_DOC")"
    if [[ "$next_doc" != /* ]]; then
      next_doc="$DOCS_DIR/$next_doc"
    fi
    if [[ -f "$next_doc" ]]; then
      CURRENT_DOC="$next_doc"
    else
      echo "状态文件指向不存在的文档：$next_doc；继续使用 $CURRENT_DOC"
      printf '%s\n' "$CURRENT_DOC" > "$STATE_CURRENT_DOC"
    fi
  fi

  if [[ ! -f "$CURRENT_DOC" ]]; then
    echo "当前迭代文档不存在：$CURRENT_DOC"
    exit 2
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  prompt_file="$PROMPT_DIR/round-${round}-${stamp}.md"
  log_file="$LOG_DIR/round-${round}-${stamp}.jsonl"
  last_message_file="$LOG_DIR/round-${round}-${stamp}.last.md"
  permission_file="$PROMPT_DIR/round-${round}-${stamp}.permissions.md"
  strategy_file="$PROMPT_DIR/round-${round}-${stamp}.strategy.md"
  requirements_file="$PROMPT_DIR/round-${round}-${stamp}.additional-requirements.md"
  context_file="$PROMPT_DIR/round-${round}-${stamp}.persistent-context.md"
  additional_requirements_block=""
  persistent_context_block=""

  if [[ "$UNRESTRICTED" == "1" ]]; then
    cat > "$permission_file" <<PERMISSIONS
权限模式：服务器隔离沙箱内的最大权限模式。

你已经被授权执行完成任务所需的全部操作，包括：

- 使用 sudo 执行系统级命令。
- 安装系统包、语言运行时、依赖、浏览器、测试工具和调试工具。
- 访问网页、搜索资料、调用网络接口、下载公开依赖和文档。
- 编写、保存、运行临时脚本或长期辅助脚本；优先放在：$SCRIPT_WORK_DIR
- 启动项目、构建项目、运行测试、运行数据库/缓存/队列/浏览器等依赖服务。
- 启动长时间运行的 dev server 或后台进程；日志和 pid 优先放在：$MONITOR_DIR
- 监控项目状态，例如 curl 健康检查、查看端口、读取日志、重启失败进程。
- 在需要时调整文件权限、执行 chmod/chown、创建目录、配置环境变量。

执行原则：

- 不要因为需要 sudo、联网、安装依赖、写脚本或运行服务而停止等待用户授权。
- 如果 sudo 需要密码导致失败，记录失败原因，并继续尝试无密码 sudo、当前用户权限、容器内 root、或文档化的替代方案。
- 对长期服务使用 nohup、setsid、tmux、systemd-run、timeout 或后台运行方式，并记录 pid、端口、日志路径和停止方式。
- 对高风险操作先确认当前是在目标项目/隔离服务器内，再执行；不要把精力花在请求人工批准上。
PERMISSIONS
  else
    cat > "$permission_file" <<PERMISSIONS
权限模式：常规自动执行模式。

- 可以修改项目、统一迭代文档目录、当前运行状态目录。
- 可以启动项目和运行测试；长时间运行服务时把 pid、端口、日志写到：$MONITOR_DIR
PERMISSIONS

    if [[ "$ALLOW_SCRIPTING" == "1" ]]; then
      cat >> "$permission_file" <<PERMISSIONS
- 可以编写、保存、运行辅助脚本；优先放在：$SCRIPT_WORK_DIR
PERMISSIONS
    fi

    if [[ "$ENABLE_SEARCH" == "1" ]]; then
      cat >> "$permission_file" <<PERMISSIONS
- 可以访问网页、搜索资料、调用网络接口、下载公开依赖和文档。
PERMISSIONS
    fi

    if [[ "$ALLOW_SUDO" == "1" ]]; then
      cat >> "$permission_file" <<PERMISSIONS
- 可以使用 sudo 执行系统级命令；如果 sudo 需要密码导致失败，记录原因并尝试可行替代方案。
PERMISSIONS
    fi

    if [[ "$ALLOW_INSTALL" == "1" ]]; then
      cat >> "$permission_file" <<PERMISSIONS
- 可以安装系统包、语言运行时、依赖、浏览器、测试工具和调试工具。
PERMISSIONS
    fi

    if [[ "$ALLOW_LONG_RUNNING" == "1" ]]; then
      cat >> "$permission_file" <<PERMISSIONS
- 可以启动长时间运行的 dev server 或后台进程；日志和 pid 优先放在：$MONITOR_DIR
PERMISSIONS
    fi

    cat >> "$permission_file" <<PERMISSIONS
- 对没有明确授权的扩大权限操作，先尝试当前权限下的可行替代方案，并把阻塞记录到文档。
PERMISSIONS
  fi

  cat > "$strategy_file" <<STRATEGY
自主迭代策略：

- 当前策略模式：$STRATEGY_MODE
- 是否主动做全面基线验证：$BASELINE_VERIFY
- 是否主动发现并规划新功能：$FEATURE_DISCOVERY
STRATEGY

  if [[ "$STRATEGY_MODE" == "conservative" ]]; then
    cat >> "$strategy_file" <<STRATEGY

保守策略：

- 优先完成当前文档指定任务。
- 当前文档完成后，可以选择修复明确 bug、补测试、补文档或做低风险重构。
- 只有当代码和文档明显支持时，才规划新功能。
STRATEGY
  else
    cat >> "$strategy_file" <<STRATEGY

进取策略：

- 当前用户给出的第一版需求文档完成后，不要停留在字段命名、格式调整、注释补充、机械重构这类低价值小改动。
- 只要项目有 git 分支和阶段性提交保护，就可以大胆推进新的完整功能，但每个功能都必须有清晰文档、独立分支、可验证行为和阶段性提交。
- 主动从项目目标、README、现有命令、用户工作流、测试缺口、错误处理、可观测性、配置体验、导入导出、性能瓶颈、部署运行体验中寻找下一个值得开发的功能。
- 新功能应该是能被用户感知或能明显改善工程闭环的完整能力，例如新增命令、自动化工作流、监控能力、配置能力、测试工具、报告能力、数据处理能力或开发体验能力。
- 除非当前项目确实还不能稳定运行，否则不要把下一轮目标限制为重命名变量、调整字段、移动文件、补少量注释或只写说明。
STRATEGY
  fi

  if [[ "$BASELINE_VERIFY" == "1" ]]; then
    cat >> "$strategy_file" <<STRATEGY

全面验证要求：

- 在开始新功能规划前，先识别并尽量运行项目的全面验证命令，包括测试、构建、lint、类型检查、格式检查、CLI smoke test、服务健康检查或端到端检查。
- 如果完整测试太慢、依赖缺失或环境不支持，要运行能代表当前风险的最大可行子集，并把未运行项、原因和后续补救写入迭代文档。
- 基线验证结果必须影响下一步选择：如果基础测试大量失败，先做能恢复开发闭环的功能或修复；如果基线健康，就进入新功能发现和实现。
STRATEGY
  fi

  if [[ "$FEATURE_DISCOVERY" == "1" ]]; then
    cat >> "$strategy_file" <<STRATEGY

新功能发现与规划要求：

- 当当前迭代文档完成或只剩低价值小任务时，必须主动生成 2 到 4 个候选新功能，并根据用户价值、工程价值、实现风险、验证成本和与项目方向的一致性选择 1 个。
- 被选中的新功能必须写成新的迭代文档，文件名优先使用 feature-${round}-<short-slug>.md。
- 新功能文档必须包含：功能目标、用户价值、现状证据、范围内行为、范围外行为、实现切片、验证矩阵、git 分支和提交计划、回滚方式、风险。
- 如果本轮还有足够时间，可以在创建新功能文档后直接开始第一个实现切片；否则把新文档路径写入状态文件，让下一轮继续开发。
- 每个新功能完成一个可验证阶段后，都要尝试提交；提交失败不应阻止继续规划，但必须记录原因。
STRATEGY
  fi

  if collect_additional_requirements "$requirements_file"; then
    additional_requirements_block="$(cat "$requirements_file")"
  else
    rm -f "$requirements_file"
  fi

  if collect_persistent_context "$context_file"; then
    persistent_context_block="$(cat "$context_file")"
  else
    rm -f "$context_file"
  fi

  cat > "$prompt_file" <<PROMPT
你是一个无人值守的 Codex 开发循环执行器。当前项目目录：

$PROJECT_DIR

统一迭代文档目录：

$DOCS_DIR

长期常驻上下文目录：

$CONTEXT_DOCS_DIR

当前运行状态目录：

$LOOP_DIR

辅助脚本目录：

$SCRIPT_WORK_DIR

服务监控目录：

$MONITOR_DIR

运行控制目录：

$CONTROL_DIR

运行中追加需求目录：

$REQUESTS_DIR

当前迭代文档：

$CURRENT_DOC

当前轮次：$round

$(cat "$permission_file")

$(cat "$strategy_file")

$persistent_context_block

$additional_requirements_block

请按以下规则工作：

1. 先阅读长期常驻上下文、当前迭代文档、相关源码、测试配置、最近日志、运行状态、README 和 git 状态。
2. 开始修改项目代码前，检查项目 git 状态和当前分支。如果项目是 git 仓库，先基于当前 HEAD 创建并切换到一个本轮专用开发分支，例如 codex/iteration-${round}-<short-slug>。只有在已经处于本轮专用分支上，或存在未提交改动导致切换不安全时，才沿用当前分支；如果沿用当前分支，必须把原因写入当前迭代文档。
3. 如果当前文档还有未完成任务，选择一个最小但有价值的切片完成开发；如果当前文档已完成，就进入全面验证和新功能发现，不要只做低价值微调。
4. 修改后运行能证明本轮改动正确的测试、构建或静态检查；在进入新功能开发前，按自主迭代策略尽量做全面基线验证。
5. 每完成一个阶段性版本并验证通过后，尝试由你自己执行 git 提交；提交应只包含本阶段相关改动，提交信息应简明说明本阶段成果。如果没有可提交内容、仓库不可写、验证失败或提交受阻，把原因写入当前迭代文档和最终回答。不要 push，除非当前迭代文档明确要求。
6. 更新当前迭代文档中的状态、已完成项、验证结果、git 分支/提交情况和剩余风险。
7. 如果当前文档已经完成或没有高价值任务，继续审查代码并提出新功能候选；优先选择完整功能或明显工程能力，不要默认选择字段命名、注释、格式化或零散小重构。
8. 当你发现下一步功能或优化方向时，在统一迭代文档目录中创建新的迭代文档。新功能文件名优先形如 feature-${round}-<short-slug>.md，其他工程改进可用 iteration-${round}-<short-slug>.md。文档必须包含目标、背景、具体任务、验证方式、停止条件、风险、git 分支和提交计划。
9. 每轮结束前，必须把下一轮应该读取的文档路径写入：

$STATE_CURRENT_DOC

只能写相对于统一迭代文档目录的文件名或相对路径，不要写绝对路径。如果仍应继续当前文档，就写当前文档相对于统一迭代文档目录的路径；如果创建了新文档，就写新文档路径。
10. 不要等待人工确认。遇到不明确处，基于现有代码和文档做保守选择。
11. 不要执行破坏性 git 操作，例如 reset --hard、clean、强推、删除未确认的大目录。
12. 除统一迭代文档目录和当前运行状态目录外，不要修改项目目录外的文件，除非当前文档明确要求。
13. 如果连续遇到同一个阻塞，记录到当前文档的“阻塞”部分，然后生成一个更小的后续文档继续绕开或缩小问题。
14. 本轮运行期间如果用户新增了需求文件，runner 会在下一轮提示词中附加；你本轮无需轮询这些目录。可用入口是：$NEXT_REQUIREMENTS_FILE 或 $REQUESTS_DIR/*.md。
15. 长期常驻上下文不会被自动消费。如果你发现其中某条长期规则已经过期，先把建议写入当前迭代文档；只有当前任务明确要求时才修改长期上下文文件。
16. 如果发现 $STOP_AFTER_CURRENT_ROUND_FILE 存在，说明用户要求 runner 在本轮结束后停止；你仍然应正常完成本轮收尾、文档更新和必要提交。
17. 最终回答只需总结本轮改动、验证结果、git 分支/提交情况、下一轮文档路径。
PROMPT

  echo "[$(date)] round=$round doc=$CURRENT_DOC log=$log_file"

  codex_invocation=("$CODEX_BIN")
  if [[ "$ENABLE_SEARCH" == "1" ]]; then
    codex_invocation+=(--search)
  fi

  cmd=(
    exec
    -C "$PROJECT_DIR"
    --add-dir "$DOCS_DIR"
    --add-dir "$CONTEXT_DOCS_DIR"
    --add-dir "$LOOP_DIR"
    --skip-git-repo-check
    --json
    --color never
    -o "$last_message_file"
  )

  if [[ -n "${CODEX_MODEL:-}" ]]; then
    cmd+=(-m "$CODEX_MODEL")
  fi
  if [[ -n "${CODEX_PROFILE:-}" ]]; then
    cmd+=(-p "$CODEX_PROFILE")
  fi

  if [[ "$DANGER_FULL_ACCESS" == "1" ]]; then
    cmd+=(--dangerously-bypass-approvals-and-sandbox)
  elif [[ "${CODEX_FULL_AUTO:-0}" == "1" ]]; then
    cmd+=(--full-auto)
  else
    cmd+=(-s "$RUNNER_SANDBOX")
    cmd+=(-c 'approval_policy="never"')
  fi

  if [[ -n "${CODEX_EXTRA_ARGS:-}" ]]; then
    # 为了简化自动化使用，这里有意按 shell 规则拆分额外参数。
    # shellcheck disable=SC2206
    extra_args=(${CODEX_EXTRA_ARGS})
    cmd+=("${extra_args[@]}")
  fi

  saved_session_id=""
  if [[ -s "$STATE_SESSION_ID" ]]; then
    saved_session_id="$(head -n 1 "$STATE_SESSION_ID")"
  fi

  if [[ ! -s "$STATE_SESSION_STARTED" ]]; then
    "${codex_invocation[@]}" "${cmd[@]}" "$(cat "$prompt_file")" > "$log_file" 2>&1
    status=$?
  elif [[ -n "$saved_session_id" ]]; then
    echo "恢复 Codex 会话：$saved_session_id"
    "${codex_invocation[@]}" "${cmd[@]}" resume "$saved_session_id" "$(cat "$prompt_file")" > "$log_file" 2>&1
    status=$?
  else
    echo "警告：已有运行状态但缺少 session_id，退回 resume --last。建议设置 CODEX_RESET_SESSION=1 重新建立显式会话。"
    "${codex_invocation[@]}" "${cmd[@]}" resume --last "$(cat "$prompt_file")" > "$log_file" 2>&1
    status=$?
  fi

  if [[ "$status" -ne 0 ]]; then
    consecutive_failures=$((consecutive_failures + 1))
    echo "Codex CLI 失败，status=$status；consecutive_failures=$consecutive_failures"
    tail -n 80 "$log_file" || true
    if [[ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
      echo "连续失败 $consecutive_failures 次，停止运行。"
      exit "$status"
    fi
  else
    consecutive_failures=0
    extracted_session_id="$(extract_session_id_from_log "$log_file" || true)"
    if [[ -n "$extracted_session_id" ]]; then
      printf '%s\n' "$extracted_session_id" > "$STATE_SESSION_ID"
    elif [[ ! -s "$STATE_SESSION_ID" ]]; then
      echo "警告：本轮成功但未能从 JSONL 日志提取 Codex session id。后续将只能退回 resume --last。"
    fi
    printf '%s\n' "$stamp" > "$STATE_SESSION_STARTED"
    printf '%s\n' "$round" > "$STATE_ROUND"
    archive_consumed_requirements
  fi

  if [[ -f "$STOP_AFTER_CURRENT_ROUND_FILE" ]]; then
    echo "当前轮结束后检测到停止标记，已完成 round=$round：$STOP_AFTER_CURRENT_ROUND_FILE"
    exit 0
  fi

  round=$((round + 1))
  sleep "$SLEEP_SECONDS"
done
