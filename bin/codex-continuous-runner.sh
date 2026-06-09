#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage:
  codex-continuous-runner.sh <project-name-or-abs-path> <seed-doc>

Example:
  CODEX_MAX_ROUNDS=0 ./bin/codex-continuous-runner.sh my-app seed-my-app.md
  CODEX_MAX_ROUNDS=0 ./bin/codex-continuous-runner.sh /srv/my-app seed-my-app.md

Environment:
  CODEX_BIN                         Codex executable, default: codex
  CODEX_MODEL                       Optional model name passed with -m
  CODEX_PROFILE                     Optional config profile passed with -p
  CODEX_PROJECTS_DIR                Project root directory, default: <framework>/projects
  CODEX_DOCS_DIR                    Iteration docs directory, default: <framework>/docs/iterations
  CODEX_RUNS_DIR                    Runtime state/log directory, default: <framework>/runs
  CODEX_RUN_NAME                    Override run directory name, default: sanitized project basename
  CODEX_UNRESTRICTED                Set to 1 for isolated-server max permission mode
  CODEX_RUNNER_SANDBOX              read-only | workspace-write | danger-full-access, default: workspace-write
  CODEX_FULL_AUTO                   Set to 1 to use --full-auto instead of explicit sandbox config
  CODEX_DANGER_FULL_ACCESS          Set to 1 to use --dangerously-bypass-approvals-and-sandbox
  CODEX_ENABLE_SEARCH               Set to 1 to pass top-level --search
  CODEX_ALLOW_SUDO                  Set to 1 to tell Codex sudo is allowed
  CODEX_ALLOW_INSTALL               Set to 1 to tell Codex dependency/system installs are allowed
  CODEX_ALLOW_LONG_RUNNING          Set to 1 to tell Codex long-running services are allowed
  CODEX_ALLOW_SCRIPTING             Set to 1 to tell Codex helper scripts are allowed
  CODEX_MAX_ROUNDS                  0 means forever, default: 0
  CODEX_SLEEP_SECONDS               Pause between rounds, default: 10
  CODEX_MAX_CONSECUTIVE_FAILURES    Stop after this many CLI failures, default: 3
  CODEX_EXTRA_ARGS                  Extra raw args appended to codex exec
  CODEX_RESET_LOOP                  Set to 1 to ignore saved run state
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
RUNNER_SANDBOX="${CODEX_RUNNER_SANDBOX:-workspace-write}"
PROJECTS_DIR="${CODEX_PROJECTS_DIR:-$FRAMEWORK_ROOT/projects}"
DOCS_DIR="${CODEX_DOCS_DIR:-$FRAMEWORK_ROOT/docs/iterations}"
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

mkdir -p "$PROJECTS_DIR" "$DOCS_DIR" "$RUNS_DIR"

if [[ "$PROJECT_ARG" = /* ]]; then
  PROJECT_DIR="$PROJECT_ARG"
else
  PROJECT_DIR="$PROJECTS_DIR/$PROJECT_ARG"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Project directory does not exist: $PROJECT_DIR"
  echo "Put projects under $PROJECTS_DIR, or pass an absolute project path."
  exit 2
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
DOCS_DIR="$(cd "$DOCS_DIR" && pwd)"
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
mkdir -p "$LOG_DIR" "$PROMPT_DIR" "$SCRIPT_WORK_DIR" "$MONITOR_DIR" "$STATE_DIR"

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
STATE_ROUND="$STATE_DIR/round"
CURRENT_DOC="$(resolve_doc_path "$SEED_DOC")"

if [[ "${CODEX_RESET_LOOP:-0}" == "1" || ! -s "$STATE_CURRENT_DOC" ]]; then
  printf '%s\n' "$CURRENT_DOC" > "$STATE_CURRENT_DOC"
fi

if [[ "${CODEX_RESET_LOOP:-0}" == "1" ]]; then
  : > "$STATE_SESSION_STARTED"
  printf '0\n' > "$STATE_ROUND"
fi

if [[ -s "$STATE_ROUND" ]] && [[ "$(head -n 1 "$STATE_ROUND")" =~ ^[0-9]+$ ]]; then
  round=$(( $(head -n 1 "$STATE_ROUND") + 1 ))
else
  round=1
fi
consecutive_failures=0

while true; do
  if [[ "$MAX_ROUNDS" != "0" && "$round" -gt "$MAX_ROUNDS" ]]; then
    echo "Reached CODEX_MAX_ROUNDS=$MAX_ROUNDS"
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
      echo "State points to missing doc: $next_doc; keeping $CURRENT_DOC"
      printf '%s\n' "$CURRENT_DOC" > "$STATE_CURRENT_DOC"
    fi
  fi

  if [[ ! -f "$CURRENT_DOC" ]]; then
    echo "Current doc does not exist: $CURRENT_DOC"
    exit 2
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  prompt_file="$PROMPT_DIR/round-${round}-${stamp}.md"
  log_file="$LOG_DIR/round-${round}-${stamp}.jsonl"
  last_message_file="$LOG_DIR/round-${round}-${stamp}.last.md"
  permission_file="$PROMPT_DIR/round-${round}-${stamp}.permissions.md"

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

  cat > "$prompt_file" <<PROMPT
你是一个无人值守的 Codex 开发循环执行器。当前项目目录：

$PROJECT_DIR

统一迭代文档目录：

$DOCS_DIR

当前运行状态目录：

$LOOP_DIR

辅助脚本目录：

$SCRIPT_WORK_DIR

服务监控目录：

$MONITOR_DIR

当前迭代文档：

$CURRENT_DOC

当前轮次：$round

$(cat "$permission_file")

请按以下规则工作：

1. 先阅读当前迭代文档、相关源码、测试配置、最近日志和 git 状态。
2. 如果当前文档还有未完成任务，选择一个最小但有价值的切片完成开发。
3. 修改后运行能证明本轮改动正确的测试、构建或静态检查。
4. 更新当前迭代文档中的状态、已完成项、验证结果和剩余风险。
5. 如果当前文档已经完成或没有高价值任务，继续审查代码，寻找下一个可改进点，例如 bug、测试缺口、结构简化、性能、可维护性、文档漂移或开发体验。
6. 当你发现下一步优化方向时，在统一迭代文档目录中创建新的迭代文档，文件名形如 iteration-${round}-<short-slug>.md。文档必须包含目标、背景、具体任务、验证方式、停止条件和风险。
7. 每轮结束前，必须把下一轮应该读取的文档路径写入：

$STATE_CURRENT_DOC

可以写绝对路径，也可以写相对于统一迭代文档目录的文件名。如果仍应继续当前文档，就写当前文档路径；如果创建了新文档，就写新文档路径。
8. 不要等待人工确认。遇到不明确处，基于现有代码和文档做保守选择。
9. 不要执行破坏性 git 操作，例如 reset --hard、clean、强推、删除未确认的大目录。
10. 除统一迭代文档目录和当前运行状态目录外，不要修改项目目录外的文件，除非当前文档明确要求。
11. 如果连续遇到同一个阻塞，记录到当前文档的 Blockers 部分，然后生成一个更小的后续文档继续绕开或缩小问题。
12. 最终回答只需总结本轮改动、验证结果、下一轮文档路径。
PROMPT

  echo "[$(date)] round=$round doc=$CURRENT_DOC log=$log_file"

  codex_global_args=()
  if [[ "$ENABLE_SEARCH" == "1" ]]; then
    codex_global_args+=(--search)
  fi

  cmd=(
    exec
    -C "$PROJECT_DIR"
    --add-dir "$DOCS_DIR"
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
    # Intentionally split extra args for simple automation use.
    # shellcheck disable=SC2206
    extra_args=(${CODEX_EXTRA_ARGS})
    cmd+=("${extra_args[@]}")
  fi

  if [[ ! -s "$STATE_SESSION_STARTED" ]]; then
    "${CODEX_BIN}" "${codex_global_args[@]}" "${cmd[@]}" "$(cat "$prompt_file")" > "$log_file" 2>&1
    status=$?
  else
    "${CODEX_BIN}" "${codex_global_args[@]}" "${cmd[@]}" resume --last "$(cat "$prompt_file")" > "$log_file" 2>&1
    status=$?
  fi

  if [[ "$status" -ne 0 ]]; then
    consecutive_failures=$((consecutive_failures + 1))
    echo "Codex CLI failed with status=$status; consecutive_failures=$consecutive_failures"
    tail -n 80 "$log_file" || true
    if [[ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
      echo "Stopping after $consecutive_failures consecutive failures."
      exit "$status"
    fi
  else
    consecutive_failures=0
    printf '%s\n' "$stamp" > "$STATE_SESSION_STARTED"
    printf '%s\n' "$round" > "$STATE_ROUND"
  fi

  round=$((round + 1))
  sleep "$SLEEP_SECONDS"
done
