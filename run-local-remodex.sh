#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$ROOT_DIR/relay"
BRIDGE_DIR="$ROOT_DIR/phodex-bridge"
ENV_FILE="${REMODEX_ENV_FILE:-$ROOT_DIR/.env.local}"
RELAY_PORT="${REMODEX_RELAY_PORT:-9000}"
RELAY_HOST="${REMODEX_RELAY_HOST:-127.0.0.1}"
RELAY_BIND_HOST="${REMODEX_RELAY_BIND_HOST:-}"
RELAY_ENTRY=""
LAN_IP_VALUE="${REMODEX_LAN_IP:-}"

usage() {
  cat <<'EOF'
Usage:
  ./run-local-remodex.sh [--relay-key <key>] [--cloudflare] [--cloudflared-token-file <path>] [--relay-url <url>] [--hostname <host>] [--port <port>] [--qr <small|none>] [--dry-run]

Options:
  --relay-key <key>   Shared relay auth key. Optional if set in .env.local.
  --cloudflare        Expose the local relay through a Cloudflare quick tunnel.
  --cloudflared-token-file <path>  Start a named tunnel from a local token file.
  --relay-url <url>   Fixed public relay URL, e.g. wss://relay.example.com/relay
  --hostname <host>   LAN hostname for bridge relay URL. Default: $(scutil --get LocalHostName).local
  --port <port>       Relay port. Default: 9000
  --qr <mode>         QR output mode. Supported: small, none. Default: small
  --dry-run           Print commands without starting services.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
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

start_in_dir_background() {
  local dir="$1"
  local log_file="$2"
  shift 2

  (
    cd "$dir"
    "$@" >"$log_file" 2>&1
  ) &

  STARTED_PID="$!"
}

detect_lan_ip() {
  if [[ -n "$LAN_IP_VALUE" ]]; then
    printf '%s\n' "$LAN_IP_VALUE"
    return
  fi

  local default_if=""
  default_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -n "$default_if" ]]; then
    local ip
    ip="$(ipconfig getifaddr "$default_if" 2>/dev/null || true)"
    ip="${ip//[$'\r\n']}"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return
    fi
  fi

  for iface in en0 en1; do
    local ip
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    ip="${ip//[$'\r\n']}"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return
    fi
  done
}

extract_cloudflare_url() {
  local log_file="$1"
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if [[ -f "$log_file" ]]; then
      local url
      url="$(python3 - <<'PY' "$log_file"
import re
import sys
text = open(sys.argv[1], "r", encoding="utf-8", errors="ignore").read()
match = re.search(r'https://[a-z0-9-]+\.trycloudflare\.com', text)
print(match.group(0) if match else "")
PY
)"
      if [[ -n "$url" ]]; then
        printf '%s\n' "$url"
        return 0
      fi
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  return 1
}

RELAY_KEY="${REMODEX_RELAY_KEY:-}"
USE_CLOUDFLARE="false"
DRY_RUN="false"
HOSTNAME_VALUE="${REMODEX_LAN_HOSTNAME:-}"
QR_MODE="${REMODEX_QR_MODE:-small}"
PUBLIC_RELAY_URL="${REMODEX_PUBLIC_RELAY_URL:-}"
TUNNEL_TOKEN_FILE="${REMODEX_CLOUDFLARED_TOKEN_FILE:-}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  RELAY_PORT="${REMODEX_RELAY_PORT:-$RELAY_PORT}"
  HOSTNAME_VALUE="${REMODEX_LAN_HOSTNAME:-$HOSTNAME_VALUE}"
  RELAY_KEY="${REMODEX_RELAY_KEY:-$RELAY_KEY}"
  QR_MODE="${REMODEX_QR_MODE:-$QR_MODE}"
  RELAY_BIND_HOST="${REMODEX_RELAY_BIND_HOST:-$RELAY_BIND_HOST}"
  PUBLIC_RELAY_URL="${REMODEX_PUBLIC_RELAY_URL:-$PUBLIC_RELAY_URL}"
  TUNNEL_TOKEN_FILE="${REMODEX_CLOUDFLARED_TOKEN_FILE:-$TUNNEL_TOKEN_FILE}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-key)
      RELAY_KEY="${2:-}"
      shift 2
      ;;
    --cloudflare)
      USE_CLOUDFLARE="true"
      shift
      ;;
    --cloudflared-token-file)
      TUNNEL_TOKEN_FILE="${2:-}"
      shift 2
      ;;
    --relay-url)
      PUBLIC_RELAY_URL="${2:-}"
      shift 2
      ;;
    --hostname)
      HOSTNAME_VALUE="${2:-}"
      shift 2
      ;;
    --port)
      RELAY_PORT="${2:-}"
      shift 2
      ;;
    --qr)
      QR_MODE="${2:-}"
      shift 2
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

if [[ -z "$RELAY_KEY" ]]; then
  echo "REMODEX_RELAY_KEY is required. Pass --relay-key or create $ENV_FILE" >&2
  usage >&2
  exit 1
fi

if [[ "$QR_MODE" != "small" && "$QR_MODE" != "none" ]]; then
  echo "Unsupported --qr mode: $QR_MODE" >&2
  usage >&2
  exit 1
fi

if [[ -n "$PUBLIC_RELAY_URL" ]]; then
  USE_CLOUDFLARE="false"
fi

if [[ -n "$TUNNEL_TOKEN_FILE" ]]; then
  USE_CLOUDFLARE="false"
fi

if [[ -n "$TUNNEL_TOKEN_FILE" && -z "$PUBLIC_RELAY_URL" ]]; then
  echo "REMODEX_PUBLIC_RELAY_URL is required when using --cloudflared-token-file" >&2
  exit 1
fi

require_command node
require_command python3

if [[ -f "$RELAY_DIR/server.cjs" ]]; then
  RELAY_ENTRY="./server.cjs"
elif [[ -f "$RELAY_DIR/server.js" ]]; then
  RELAY_ENTRY="./server.js"
else
  echo "Missing relay entrypoint: expected $RELAY_DIR/server.cjs or $RELAY_DIR/server.js" >&2
  exit 1
fi

if [[ "$USE_CLOUDFLARE" == "true" || -n "$TUNNEL_TOKEN_FILE" ]]; then
  require_command cloudflared
fi

if [[ -z "$HOSTNAME_VALUE" && "$USE_CLOUDFLARE" == "false" ]]; then
  if scutil --get LocalHostName >/dev/null 2>&1; then
    HOSTNAME_VALUE="$(scutil --get LocalHostName).local"
  else
    HOSTNAME_VALUE="$(hostname).local"
  fi
fi

if [[ -z "$RELAY_BIND_HOST" ]]; then
  if [[ "$USE_CLOUDFLARE" == "true" || -n "$TUNNEL_TOKEN_FILE" ]]; then
    RELAY_BIND_HOST="127.0.0.1"
  else
    RELAY_BIND_HOST="0.0.0.0"
  fi
fi

RELAY_LOG="$(mktemp -t remodex-relay-log.XXXXXX)"
TUNNEL_LOG=""

cleanup() {
  local exit_code=$?
  if [[ -n "${BRIDGE_PID:-}" ]]; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${RELAY_PID:-}" ]]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

trap cleanup INT TERM EXIT

if [[ "$DRY_RUN" == "false" ]]; then
  print_cmd env "HOST=$RELAY_BIND_HOST" "PORT=$RELAY_PORT" "REMODEX_RELAY_KEY=$RELAY_KEY" node "$RELAY_ENTRY" '>' "$RELAY_LOG" "2>&1" '&' "(cwd: $RELAY_DIR)"
  start_in_dir_background "$RELAY_DIR" "$RELAY_LOG" env "HOST=$RELAY_BIND_HOST" "PORT=$RELAY_PORT" "REMODEX_RELAY_KEY=$RELAY_KEY" node "$RELAY_ENTRY"
  RELAY_PID="$STARTED_PID"
  sleep 1
  if ! curl -sf "http://$RELAY_HOST:$RELAY_PORT/health" >/dev/null; then
    echo "Relay failed to start. Log:" >&2
    cat "$RELAY_LOG" >&2
    exit 1
  fi
else
  print_cmd env "HOST=$RELAY_BIND_HOST" "PORT=$RELAY_PORT" "REMODEX_RELAY_KEY=$RELAY_KEY" node "$RELAY_ENTRY" '>' "$RELAY_LOG" "2>&1" '&' "(cwd: $RELAY_DIR)"
  RELAY_PID=""
fi

if [[ -n "$TUNNEL_TOKEN_FILE" ]]; then
  TUNNEL_LOG="$(mktemp -t remodex-cloudflared-log.XXXXXX)"
  if [[ "$DRY_RUN" == "true" ]]; then
    print_cmd cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT" run --token-file "$TUNNEL_TOKEN_FILE" '>' "$TUNNEL_LOG" "2>&1" '&'
  else
    print_cmd cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT" run --token-file "$TUNNEL_TOKEN_FILE" '>' "$TUNNEL_LOG" "2>&1" '&'
    start_in_dir_background "$ROOT_DIR" "$TUNNEL_LOG" cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT" run --token-file "$TUNNEL_TOKEN_FILE"
    TUNNEL_PID="$STARTED_PID"
    sleep 2
  fi
  RELAY_URL="$PUBLIC_RELAY_URL"
elif [[ -n "$PUBLIC_RELAY_URL" ]]; then
  RELAY_URL="$PUBLIC_RELAY_URL"
elif [[ "$USE_CLOUDFLARE" == "true" ]]; then
  TUNNEL_LOG="$(mktemp -t remodex-cloudflared-log.XXXXXX)"
  if [[ "$DRY_RUN" == "true" ]]; then
    print_cmd cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT" '>' "$TUNNEL_LOG" "2>&1" '&'
    RELAY_URL="wss://<trycloudflare-host>/relay"
  else
    print_cmd cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT" '>' "$TUNNEL_LOG" "2>&1" '&'
    start_in_dir_background "$ROOT_DIR" "$TUNNEL_LOG" cloudflared tunnel --protocol http2 --url "http://$RELAY_HOST:$RELAY_PORT"
    TUNNEL_PID="$STARTED_PID"
    TUNNEL_HTTP_URL="$(extract_cloudflare_url "$TUNNEL_LOG")"
    if [[ -z "$TUNNEL_HTTP_URL" ]]; then
      echo "Failed to get TryCloudflare URL. Log:" >&2
      cat "$TUNNEL_LOG" >&2
      exit 1
    fi
    RELAY_URL="${TUNNEL_HTTP_URL/https:/wss:}/relay"
  fi
else
  RELAY_URL="ws://$HOSTNAME_VALUE:$RELAY_PORT/relay"
fi

LOCAL_RELAY_CANDIDATE="ws://$HOSTNAME_VALUE:$RELAY_PORT/relay"
LAN_IP_CANDIDATE=""
LAN_IP_DETECTED="$(detect_lan_ip || true)"
if [[ -n "$LAN_IP_DETECTED" ]]; then
  LAN_IP_CANDIDATE="ws://$LAN_IP_DETECTED:$RELAY_PORT/relay"
fi

# Keep local/LAN candidates first to avoid cloud/local session split,
# while still preserving public relay fallback.
candidate_set_add() {
  local next_candidate="$1"
  if [[ -z "${next_candidate:-}" ]]; then
    return
  fi
  if [[ -z "${RELAY_CANDIDATES:-}" ]]; then
    RELAY_CANDIDATES="$next_candidate"
    return
  fi
  case ",$RELAY_CANDIDATES," in
    *",$next_candidate,"*) ;;
    *) RELAY_CANDIDATES="$RELAY_CANDIDATES,$next_candidate" ;;
  esac
}

RELAY_CANDIDATES=""
candidate_set_add "$LOCAL_RELAY_CANDIDATE"
candidate_set_add "$LAN_IP_CANDIDATE"
candidate_set_add "$RELAY_URL"

BRIDGE_PAIRING_CODE_ENV=""
if [[ "$QR_MODE" == "none" ]]; then
  BRIDGE_PAIRING_CODE_ENV="true"
else
  BRIDGE_PAIRING_CODE_ENV="${REMODEX_PRINT_PAIRING_CODE:-false}"
fi

echo "Copy/Paste values:"
echo "  REMODEX_RELAY=$RELAY_URL"
echo "  REMODEX_RELAY_CANDIDATES=$RELAY_CANDIDATES"
if [[ -n "$LAN_IP_DETECTED" ]]; then
  echo "  REMODEX_LAN_IP=$LAN_IP_DETECTED"
fi
echo "  REMODEX_RELAY_KEY=$RELAY_KEY"
echo "  REMODEX_QR_MODE=$QR_MODE"
echo "  REMODEX_PRINT_PAIRING_CODE=$BRIDGE_PAIRING_CODE_ENV"
echo "  RUN_CMD=cd \"$BRIDGE_DIR\" && REMODEX_RELAY=\"$RELAY_URL\" REMODEX_RELAY_CANDIDATES=\"$RELAY_CANDIDATES\" REMODEX_RELAY_KEY=\"$RELAY_KEY\" REMODEX_QR_MODE=\"$QR_MODE\" REMODEX_PRINT_PAIRING_CODE=\"$BRIDGE_PAIRING_CODE_ENV\" node ./bin/remodex.js up"

print_cmd bash -lc "cd $(printf '%q' "$BRIDGE_DIR") && REMODEX_RELAY=$(printf '%q' "$RELAY_URL") REMODEX_RELAY_CANDIDATES=$(printf '%q' "$RELAY_CANDIDATES") REMODEX_RELAY_KEY=$(printf '%q' "$RELAY_KEY") REMODEX_QR_MODE=$(printf '%q' "$QR_MODE") REMODEX_PRINT_PAIRING_CODE=$(printf '%q' "$BRIDGE_PAIRING_CODE_ENV") node ./bin/remodex.js up"

if [[ "$DRY_RUN" == "true" ]]; then
  exit 0
fi

cd "$BRIDGE_DIR"
REMODEX_RELAY="$RELAY_URL" \
REMODEX_RELAY_CANDIDATES="$RELAY_CANDIDATES" \
REMODEX_RELAY_KEY="$RELAY_KEY" \
REMODEX_QR_MODE="$QR_MODE" \
REMODEX_PRINT_PAIRING_CODE="$BRIDGE_PAIRING_CODE_ENV" \
node ./bin/remodex.js up &
BRIDGE_PID=$!
wait "$BRIDGE_PID"
