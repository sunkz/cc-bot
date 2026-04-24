#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SERVER_URL="${CCBOT_NOTIFY_SERVER_URL:-http://localhost:62400}"
TOKEN_FILE="${CCBOT_NOTIFY_TOKEN_FILE:-$HOME/.claude/hooks/.ccbot-auth}"
GAP_SECONDS=0
DRY_RUN=0
INCLUDE_CCGUI=0
ONLY_ITEMS=""
LIST_ITEMS=0

CURRENT_REPO_CWD="$(pwd -P)"
CODEX_COMPLETION_CWD="${CCBOT_SAMPLE_CODEX_COMPLETION_CWD:-$CURRENT_REPO_CWD}"
CODEX_INPUT_CWD="${CCBOT_SAMPLE_CODEX_INPUT_CWD:-$CURRENT_REPO_CWD}"
CODEX_APPROVAL_CWD="${CCBOT_SAMPLE_CODEX_APPROVAL_CWD:-/Users/kezheng.sun/code/cc-space}"
CODEX_APPROVAL_COMMAND_CWD="${CCBOT_SAMPLE_CODEX_APPROVAL_COMMAND_CWD:-$CURRENT_REPO_CWD}"
CLAUDE_COMPLETION_CWD="${CCBOT_SAMPLE_CLAUDE_COMPLETION_CWD:-$CURRENT_REPO_CWD}"
CLAUDE_INPUT_CWD="${CCBOT_SAMPLE_CLAUDE_INPUT_CWD:-$CURRENT_REPO_CWD}"
CLAUDE_APPROVAL_CWD="${CCBOT_SAMPLE_CLAUDE_APPROVAL_CWD:-/Users/kezheng.sun/code/blog}"
CLAUDE_INFO_CWD="${CCBOT_SAMPLE_CLAUDE_INFO_CWD:-$CURRENT_REPO_CWD}"
RUN_ID="${CCBOT_SAMPLE_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"

DEFAULT_ITEMS=(
  codex-completion
  codex-completion-structured
  codex-input
  codex-approval
  codex-approval-command
  claude-completion
  claude-input
  claude-approval
  claude-info
)

CCGUI_ITEMS=(
  ccgui-input
  ccgui-approval
  ccgui-request
)

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME [--dry-run] [--gap 秒数] [--only 名称列表] [--include-ccgui] [--list-items]

说明:
  通过本机 CCBot HookServer 发送一组示例通知，便于手动截图。

默认发送:
  codex-completion
  codex-completion-structured
  codex-input
  codex-approval
  codex-approval-command
  claude-completion
  claude-input
  claude-approval
  claude-info

可选项:
  --dry-run         只打印将要发送的请求，不实际调用 HookServer
  --gap N           每条通知之间等待 N 秒，默认 0
  --only LIST       只发送指定通知，逗号分隔
  --include-ccgui   在默认集合后额外写入 3 个 CC GUI 示例文件
  --list-items      打印所有可用场景名称和说明
  -h, --help        显示帮助

环境变量:
  CCBOT_NOTIFY_SERVER_URL        HookServer 地址，默认 http://localhost:62400
  CCBOT_NOTIFY_TOKEN_FILE        认证 token 文件，默认 ~/.claude/hooks/.ccbot-auth
  CCBOT_SAMPLE_CODEX_COMPLETION_CWD
  CCBOT_SAMPLE_CODEX_INPUT_CWD
  CCBOT_SAMPLE_CODEX_APPROVAL_CWD
  CCBOT_SAMPLE_CODEX_APPROVAL_COMMAND_CWD
  CCBOT_SAMPLE_CLAUDE_COMPLETION_CWD
  CCBOT_SAMPLE_CLAUDE_INPUT_CWD
  CCBOT_SAMPLE_CLAUDE_APPROVAL_CWD
  CCBOT_SAMPLE_CLAUDE_INFO_CWD
EOF
}

die() {
  echo "[$SCRIPT_NAME] $*" >&2
  exit 1
}

log() {
  echo "[$SCRIPT_NAME] $*"
}

list_items() {
  cat <<EOF
可用场景:
  codex-completion            Codex 普通完成通知，正文是纯文本总结
  codex-completion-structured Codex 完成通知，正文是结构化 suggestions payload
  codex-input                 Codex 等待输入，走 input-messages
  codex-approval              Codex 待确认，优先展示 description
  codex-approval-command      Codex 待确认，覆盖 command fallback
  claude-completion           Claude stop/completion 路径
  claude-input                Claude 等待输入通知
  claude-approval             Claude 权限确认通知
  claude-info                 Claude 普通信息通知
  ccgui-input                 CC GUI ask-user-question 文件
  ccgui-approval              CC GUI plan-approval 文件
  ccgui-request               CC GUI request 文件，受 watcher 1.5s grace period 影响
EOF
}

contains_item() {
  local item="$1"
  if [[ -z "$ONLY_ITEMS" ]]; then
    return 0
  fi
  local padded=",$ONLY_ITEMS,"
  [[ "$padded" == *",$item,"* ]]
}

validate_only_items() {
  if [[ -z "$ONLY_ITEMS" ]]; then
    return 0
  fi

  local item
  IFS=',' read -r -a items <<< "$ONLY_ITEMS"
  for item in "${items[@]}"; do
    case "$item" in
      codex-completion|codex-completion-structured|codex-input|codex-approval|codex-approval-command|claude-completion|claude-input|claude-approval|claude-info|ccgui-input|ccgui-approval|ccgui-request) ;;
      *)
        die "不支持的 --only 值: $item"
        ;;
    esac
  done
}

check_server() {
  if (( DRY_RUN )); then
    return 0
  fi

  curl -sf "$SERVER_URL/health" >/dev/null \
    || die "HookServer 不可用，请先启动 CCBot，并确认 $SERVER_URL/health 可访问"
}

needs_http_dispatch() {
  local item

  if [[ -z "$ONLY_ITEMS" ]]; then
    return 0
  fi

  for item in "${DEFAULT_ITEMS[@]}"; do
    if contains_item "$item"; then
      return 0
    fi
  done

  return 1
}

read_token() {
  if (( DRY_RUN )); then
    echo "__DRY_RUN_TOKEN__"
    return 0
  fi

  [[ -f "$TOKEN_FILE" ]] || die "找不到 token 文件: $TOKEN_FILE"
  local token
  token="$(<"$TOKEN_FILE")"
  [[ -n "$token" ]] || die "token 文件为空: $TOKEN_FILE"
  echo "$token"
}

post_json() {
  local label="$1"
  local path="$2"
  local body="$3"
  local token="$4"

  log "发送 $label"
  if (( DRY_RUN )); then
    cat <<EOF
POST $SERVER_URL$path
Authorization: Bearer $token
Content-Type: application/json

$body

EOF
    return 0
  fi

  curl -sf -X POST "$SERVER_URL$path" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
}

write_ccgui_file() {
  local label="$1"
  local file_name="$2"
  local body="$3"
  local permission_dir="${CLAUDE_PERMISSION_DIR:-${TMPDIR%/}/claude-permission}"

  log "写入 $label: $permission_dir/$file_name"
  if (( DRY_RUN )); then
    cat <<EOF
WRITE $permission_dir/$file_name

$body

EOF
    return 0
  fi

  mkdir -p "$permission_dir"
  printf '%s\n' "$body" > "$permission_dir/$file_name"
}

wait_gap() {
  local seconds="$1"
  if (( DRY_RUN )); then
    return 0
  fi
  if [[ "$seconds" == "0" ]]; then
    return 0
  fi
  log "等待 ${seconds}s，留给你截图"
  sleep "$seconds"
}

dispatch_item() {
  local item="$1"
  local token="$2"
  local body=""

  case "$item" in
    codex-completion)
      body="{\"type\":\"agent-turn-complete\",\"cwd\":\"$CODEX_COMPLETION_CWD\",\"last-assistant-message\":\"已完成 README 截图重拍，现已覆盖完成、待确认、待输入三类通知。\",\"session_id\":\"readme-shot-codex-completion-$RUN_ID\"}"
      post_json "$item" "/hook/codex-notify" "$body" "$token"
      ;;
    codex-completion-structured)
      body="{\"type\":\"agent-turn-complete\",\"cwd\":\"$CODEX_COMPLETION_CWD\",\"last-assistant-message\":\"{\\\"suggestions\\\":[{\\\"title\\\":\\\"只替换 README 正式引用图\\\",\\\"description\\\":\\\"保持 docs/images 路径不变\\\"},{\\\"title\\\":\\\"保留菜单栏窗口图\\\",\\\"description\\\":\\\"通知图与配置图分开展示\\\"}]}\",\"session_id\":\"readme-shot-codex-structured-$RUN_ID\"}"
      post_json "$item" "/hook/codex-notify" "$body" "$token"
      ;;
    codex-input)
      body="{\"type\":\"user-input-requested\",\"cwd\":\"$CODEX_INPUT_CWD\",\"input-messages\":[\"README 首页是否改成竖向堆叠通知图？\"],\"session_id\":\"readme-shot-codex-input-$RUN_ID\"}"
      post_json "$item" "/hook/codex-notify" "$body" "$token"
      ;;
    codex-approval)
      body="{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$CODEX_APPROVAL_CWD\",\"tool_input\":{\"description\":\"执行 git push origin main，同步 README 截图更新\"},\"request_id\":\"readme-shot-codex-approval-$RUN_ID\"}"
      post_json "$item" "/hook/codex-permission-request" "$body" "$token"
      ;;
    codex-approval-command)
      body="{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$CODEX_APPROVAL_COMMAND_CWD\",\"tool_input\":{\"command\":\"git push --force-with-lease\"},\"request_id\":\"readme-shot-codex-approval-command-$RUN_ID\"}"
      post_json "$item" "/hook/codex-permission-request" "$body" "$token"
      ;;
    claude-completion)
      body="{\"cwd\":\"$CLAUDE_COMPLETION_CWD\",\"last_assistant_message\":\"README 截图已更新完成，可以回到仓库检查最终展示效果。\",\"session_id\":\"readme-shot-claude-completion-$RUN_ID\"}"
      post_json "$item" "/hook/stop" "$body" "$token"
      ;;
    claude-input)
      body="{\"cwd\":\"$CLAUDE_INPUT_CWD\",\"message\":\"Claude needs your input to confirm the README screenshot layout.\",\"session_id\":\"readme-shot-claude-input-$RUN_ID\"}"
      post_json "$item" "/hook/notification" "$body" "$token"
      ;;
    claude-approval)
      body="{\"cwd\":\"$CLAUDE_APPROVAL_CWD\",\"message\":\"Claude Code needs your permission to use Bash.\",\"session_id\":\"readme-shot-claude-approval-$RUN_ID\"}"
      post_json "$item" "/hook/notification" "$body" "$token"
      ;;
    claude-info)
      body="{\"cwd\":\"$CLAUDE_INFO_CWD\",\"message\":\"README 截图资源已生成到 docs/images，可继续检查最终排版。\",\"session_id\":\"readme-shot-claude-info-$RUN_ID\"}"
      post_json "$item" "/hook/notification" "$body" "$token"
      ;;
    ccgui-input)
      write_ccgui_file \
        "$item" \
        "ask-user-question-readme-shot-$RUN_ID.json" \
        "{\"cwd\":\"$CURRENT_REPO_CWD\",\"question\":\"README 首页是否改成并排展示 4 类真实通知？\",\"toolName\":\"ask-user-question\"}"
      ;;
    ccgui-approval)
      write_ccgui_file \
        "$item" \
        "plan-approval-readme-shot-$RUN_ID.json" \
        "{\"cwd\":\"$CURRENT_REPO_CWD\",\"summary\":\"需要确认发布计划：同步 docs/images 新截图并保留旧版引用兼容。\",\"toolName\":\"plan-approval\"}"
      ;;
    ccgui-request)
      write_ccgui_file \
        "$item" \
        "request-readme-shot-$RUN_ID.json" \
        "{\"cwd\":\"$CURRENT_REPO_CWD\",\"toolName\":\"Bash\",\"description\":\"执行 git status --short，确认 README 截图替换范围\"}"
      ;;
    *)
      die "内部错误：未识别的通知项 $item"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --gap)
      [[ $# -ge 2 ]] || die "--gap 需要一个数字参数"
      GAP_SECONDS="$2"
      shift 2
      ;;
    --only)
      [[ $# -ge 2 ]] || die "--only 需要一个逗号分隔列表"
      ONLY_ITEMS="$2"
      shift 2
      ;;
    --include-ccgui)
      INCLUDE_CCGUI=1
      shift
      ;;
    --list-items)
      LIST_ITEMS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

[[ "$GAP_SECONDS" =~ ^[0-9]+$ ]] || die "--gap 必须是非负整数"
validate_only_items

if (( LIST_ITEMS )); then
  list_items
  exit 0
fi

TOKEN=""
if needs_http_dispatch; then
  TOKEN="$(read_token)"
  check_server
fi

if [[ -n "$ONLY_ITEMS" ]]; then
  for item in "${DEFAULT_ITEMS[@]}" "${CCGUI_ITEMS[@]}"; do
    if contains_item "$item"; then
      dispatch_item "$item" "$TOKEN"
      wait_gap "$GAP_SECONDS"
    fi
  done
else
  for item in "${DEFAULT_ITEMS[@]}"; do
    dispatch_item "$item" "$TOKEN"
    wait_gap "$GAP_SECONDS"
  done

  if (( INCLUDE_CCGUI )); then
    for item in "${CCGUI_ITEMS[@]}"; do
      dispatch_item "$item" "$TOKEN"
      wait_gap "$GAP_SECONDS"
    done
  fi
fi

log "已完成。你可以按需要重跑某一类通知，例如:"
log "  $SCRIPT_NAME --only codex-completion-structured"
