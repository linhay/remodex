#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$ROOT_DIR/run-local-remodex.sh"
LABEL="com.linhay.remodex.autostart"
AGENT_DIR="$HOME/Library/LaunchAgents"
ACTION="install"
DRY_RUN="false"

TOKEN_FILE="${REMODEX_CLOUDFLARED_TOKEN_FILE:-}"
PUBLIC_RELAY_URL="${REMODEX_PUBLIC_RELAY_URL:-}"
RELAY_KEY="${REMODEX_RELAY_KEY:-}"
LAUNCHD_PATH="${REMODEX_LAUNCHD_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

usage() {
  cat <<'EOF'
Usage:
  ./setup-remodex-launchd.sh --token-file <path> --public-relay-url <wss-url> [--relay-key <key>] [--label <launchd-label>] [--agent-dir <dir>] [--dry-run]
  ./setup-remodex-launchd.sh --uninstall [--label <launchd-label>] [--agent-dir <dir>] [--dry-run]
  ./setup-remodex-launchd.sh --status [--label <launchd-label>]

Options:
  --token-file <path>       Cloudflared named tunnel token file path.
  --public-relay-url <url>  Public relay URL, e.g. wss://relay.section.trade/relay
  --relay-key <key>         Shared relay auth key. Optional if REMODEX_RELAY_KEY is already set.
  --label <label>           Launchd label. Default: com.linhay.remodex.autostart
  --agent-dir <dir>         LaunchAgents directory. Default: ~/Library/LaunchAgents
  --uninstall               Remove and unload launchd item.
  --status                  Print launchd status for current label.
  --dry-run                 Print actions only, without writing/loading.
EOF
}

print_cmd() {
  printf '+'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_cmd() {
  print_cmd "$@"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  "$@"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token-file)
      TOKEN_FILE="${2:-}"
      shift 2
      ;;
    --public-relay-url)
      PUBLIC_RELAY_URL="${2:-}"
      shift 2
      ;;
    --relay-key)
      RELAY_KEY="${2:-}"
      shift 2
      ;;
    --label)
      LABEL="${2:-}"
      shift 2
      ;;
    --agent-dir)
      AGENT_DIR="${2:-}"
      shift 2
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PLIST_PATH="$AGENT_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/remodex"
STDOUT_LOG="$LOG_DIR/$LABEL.out.log"
STDERR_LOG="$LOG_DIR/$LABEL.err.log"
UID_VALUE="$(id -u)"

build_plist() {
  local escaped_label escaped_root escaped_script escaped_token escaped_url escaped_key escaped_stdout escaped_stderr escaped_path
  escaped_label="$(xml_escape "$LABEL")"
  escaped_root="$(xml_escape "$ROOT_DIR")"
  escaped_script="$(xml_escape "$RUN_SCRIPT")"
  escaped_token="$(xml_escape "$TOKEN_FILE")"
  escaped_url="$(xml_escape "$PUBLIC_RELAY_URL")"
  escaped_key="$(xml_escape "$RELAY_KEY")"
  escaped_path="$(xml_escape "$LAUNCHD_PATH")"
  escaped_stdout="$(xml_escape "$STDOUT_LOG")"
  escaped_stderr="$(xml_escape "$STDERR_LOG")"

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$escaped_label</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>$escaped_root</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$escaped_script</string>
    <string>--cloudflared-token-file</string>
    <string>$escaped_token</string>
    <string>--relay-url</string>
    <string>$escaped_url</string>
    <string>--qr</string>
    <string>none</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>REMODEX_RELAY_KEY</key>
    <string>$escaped_key</string>
    <key>REMODEX_PAIRING_TTL_MS</key>
    <string>never</string>
    <key>REMODEX_PRINT_PAIRING_CODE</key>
    <string>true</string>
    <key>PATH</key>
    <string>$escaped_path</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$escaped_stdout</string>
  <key>StandardErrorPath</key>
  <string>$escaped_stderr</string>
</dict>
</plist>
EOF
}

ensure_required_for_install() {
  if [[ -z "$TOKEN_FILE" ]]; then
    echo "--token-file is required for install" >&2
    exit 1
  fi
  if [[ -z "$PUBLIC_RELAY_URL" ]]; then
    echo "--public-relay-url is required for install" >&2
    exit 1
  fi
  if [[ -z "$RELAY_KEY" ]]; then
    echo "--relay-key is required for install (or set REMODEX_RELAY_KEY)" >&2
    exit 1
  fi
  if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "Missing runner script: $RUN_SCRIPT" >&2
    exit 1
  fi
}

launchd_bootout_if_loaded() {
  if launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1; then
    run_cmd launchctl bootout "gui/$UID_VALUE" "$PLIST_PATH"
  fi
}

install_action() {
  ensure_required_for_install

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run: would write plist to $PLIST_PATH"
    build_plist
    return 0
  fi

  run_cmd mkdir -p "$AGENT_DIR"
  run_cmd mkdir -p "$LOG_DIR"
  build_plist >"$PLIST_PATH"
  echo "Wrote: $PLIST_PATH"

  launchd_bootout_if_loaded || true
  run_cmd launchctl bootstrap "gui/$UID_VALUE" "$PLIST_PATH"
  run_cmd launchctl enable "gui/$UID_VALUE/$LABEL"
  run_cmd launchctl kickstart -k "gui/$UID_VALUE/$LABEL"
  echo "Installed and started: $LABEL"
}

uninstall_action() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run: would unload and remove $PLIST_PATH"
    return 0
  fi

  if launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1; then
    run_cmd launchctl bootout "gui/$UID_VALUE" "$PLIST_PATH"
  fi

  if [[ -f "$PLIST_PATH" ]]; then
    run_cmd rm -f "$PLIST_PATH"
    echo "Removed: $PLIST_PATH"
  else
    echo "No plist found: $PLIST_PATH"
  fi
}

status_action() {
  print_cmd launchctl print "gui/$UID_VALUE/$LABEL"
  launchctl print "gui/$UID_VALUE/$LABEL"
}

case "$ACTION" in
  install)
    install_action
    ;;
  uninstall)
    uninstall_action
    ;;
  status)
    status_action
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 1
    ;;
esac
