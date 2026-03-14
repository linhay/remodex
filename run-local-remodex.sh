#!/usr/bin/env bash

# FILE: run-local-remodex.sh
# Purpose: Start a local Remodex relay and bridge with sensible LAN defaults.
# Layer: developer utility
# Exports: none

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${ROOT_DIR}/phodex-bridge"
RELAY_MODULE="${BRIDGE_DIR}/src/relay-core.js"

RELAY_HOST="${RELAY_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-9000}"
RELAY_PUBLIC_HOST="${RELAY_PUBLIC_HOST:-}"
RELAY_URL="${RELAY_URL:-}"
RELAY_URL_WAS_SET=0
DRY_RUN=0

RELAY_PID=""
BRIDGE_DEPENDENCIES=("ws" "qrcode-terminal" "uuid")

log() {
  echo "[run-local-remodex] $*"
}

warn() {
  echo "[run-local-remodex] Warning: $*" >&2
}

die() {
  echo "[run-local-remodex] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./run-local-remodex.sh [options]

Options:
  --hostname HOSTNAME   Hostname or IP advertised to the bridge for relay access
  --bind-host HOST      Interface/address the local relay should listen on
  --port PORT           Relay port to listen on and advertise
  --dry-run             Print the resolved configuration without starting processes
  --help                Show this help text

Environment overrides:
  RELAY_PUBLIC_HOST     Same as --hostname
  RELAY_HOST            Same as --bind-host
  RELAY_PORT            Same as --port
  RELAY_URL             Full relay URL override (for example ws://host:9000/relay)

Defaults:
  bind host             0.0.0.0
  port                  9000
  hostname              macOS LocalHostName + ".local", then hostname, then localhost
EOF
}

require_value() {
  local flag_name="$1"
  local remaining_args="$2"
  [[ "${remaining_args}" -ge 2 ]] || die "${flag_name} requires a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)
        require_value "--hostname" "$#"
        RELAY_PUBLIC_HOST="$2"
        shift 2
        ;;
      --bind-host)
        require_value "--bind-host" "$#"
        RELAY_HOST="$2"
        shift 2
        ;;
      --port)
        require_value "--port" "$#"
        RELAY_PORT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "[run-local-remodex] Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

default_public_host() {
  if [[ -n "${RELAY_PUBLIC_HOST}" ]]; then
    printf '%s\n' "${RELAY_PUBLIC_HOST}"
    return
  fi

  if command -v scutil >/dev/null 2>&1; then
    local local_host_name
    local_host_name="$(scutil --get LocalHostName 2>/dev/null || true)"
    local_host_name="${local_host_name//[$'\r\n']}"
    if [[ -n "${local_host_name}" ]]; then
      printf '%s.local\n' "${local_host_name}"
      return
    fi
  fi

  local host_name
  host_name="$(hostname 2>/dev/null || true)"
  host_name="${host_name//[$'\r\n']}"
  if [[ -n "${host_name}" ]]; then
    printf '%s\n' "${host_name}"
    return
  fi

  printf 'localhost\n'
}

healthcheck_host() {
  case "${RELAY_HOST}" in
    ""|"0.0.0.0")
      printf '127.0.0.1\n'
      ;;
    "::")
      printf '[::1]\n'
      ;;
    *)
      printf '%s\n' "${RELAY_HOST}"
      ;;
  esac
}

cleanup() {
  if [[ -n "${RELAY_PID}" ]] && kill -0 "${RELAY_PID}" 2>/dev/null; then
    kill "${RELAY_PID}" 2>/dev/null || true
    wait "${RELAY_PID}" 2>/dev/null || true
  fi
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "Missing required command: ${command_name}"
}

require_supported_node() {
  local node_version
  local node_major

  node_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  [[ -n "${node_version}" ]] || die "Unable to determine the installed Node.js version."

  node_major="${node_version%%.*}"
  [[ "${node_major}" =~ ^[0-9]+$ ]] || die "Unable to parse the installed Node.js version: ${node_version}"

  if (( node_major < 18 )); then
    die "Please use Node.js 18 or greater."
  fi
}

ensure_prerequisites() {
  require_command node
  require_supported_node
  require_command npm
  require_command curl
  require_command lsof
  require_command python3
}

bridge_dependencies_installed() {
  local dependency
  for dependency in "${BRIDGE_DEPENDENCIES[@]}"; do
    [[ -d "${BRIDGE_DIR}/node_modules/${dependency}" ]] || return 1
  done
  return 0
}

ensure_dependencies() {
  bridge_dependencies_installed || die "Bridge dependencies are missing. Run 'cd ${BRIDGE_DIR} && npm install' first."
}

ensure_port_available() {
  if lsof -nP -iTCP:"${RELAY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port ${RELAY_PORT} is already in use. Stop the existing listener or rerun with --port."
  fi
}

wait_for_relay() {
  local attempt
  local probe_host
  probe_host="$(healthcheck_host)"
  for attempt in {1..20}; do
    if [[ -n "${RELAY_PID}" ]] && ! kill -0 "${RELAY_PID}" 2>/dev/null; then
      echo "[run-local-remodex] Relay process exited before becoming healthy." >&2
      return 1
    fi
    if curl --silent --fail "http://${probe_host}:${RELAY_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  echo "[run-local-remodex] Relay did not become healthy on port ${RELAY_PORT}." >&2
  return 1
}

print_host_notice() {
  if [[ "${RELAY_URL_WAS_SET}" -eq 1 ]]; then
    return
  fi

  if ! python3 - <<'PY' "${RELAY_PUBLIC_HOST}" >/dev/null 2>&1
import socket
import sys

socket.gethostbyname(sys.argv[1])
PY
  then
    warn "${RELAY_PUBLIC_HOST} does not currently resolve on this machine."
  fi
}

start_embedded_relay() {
  log "Starting relay on ${RELAY_HOST}:${RELAY_PORT}..."

  HOST="${RELAY_HOST}" \
  PORT="${RELAY_PORT}" \
  NODE_PATH="${BRIDGE_DIR}/node_modules${NODE_PATH:+:${NODE_PATH}}" \
  RELAY_MODULE="${RELAY_MODULE}" \
  node <<'NODE' &
const http = require("node:http");
const { WebSocketServer } = require("ws");
const { setupRelay, getRelayStats } = require(process.env.RELAY_MODULE);

const host = process.env.HOST || "0.0.0.0";
const port = Number.parseInt(process.env.PORT || "9000", 10);

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    const body = JSON.stringify({ ok: true, ...getRelayStats() });
    res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    res.end(body);
    return;
  }

  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("Not found");
});

const wss = new WebSocketServer({ server });
setupRelay(wss);

server.listen(port, host, () => {
  console.log(`[relay] listening on http://${host}:${port}`);
});

function shutdown() {
  wss.close(() => {
    server.close(() => process.exit(0));
  });
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
NODE

  RELAY_PID=$!
}

print_runtime_summary() {
  cat <<EOF
[run-local-remodex] Configuration
  Relay bind host : ${RELAY_HOST}
  Relay port      : ${RELAY_PORT}
  Relay hostname  : ${RELAY_PUBLIC_HOST}
  Relay URL       : ${RELAY_URL}
EOF
}

print_dry_run() {
  print_runtime_summary
  if [[ "${RELAY_URL_WAS_SET}" -eq 0 ]]; then
    echo "[run-local-remodex] Dry run: would start embedded relay on ${RELAY_HOST}:${RELAY_PORT}"
  else
    echo "[run-local-remodex] Dry run: would skip embedded relay because RELAY_URL is set."
  fi
  echo "[run-local-remodex] Dry run: REMODEX_RELAY=${RELAY_URL} node ./bin/remodex.js up"
}

start_bridge() {
  log "Starting bridge with REMODEX_RELAY=${RELAY_URL}"
  cd "${BRIDGE_DIR}"
  REMODEX_RELAY="${RELAY_URL}" node ./bin/remodex.js up
}

trap cleanup EXIT INT TERM

parse_args "$@"

if [[ -n "${RELAY_URL}" ]]; then
  RELAY_URL_WAS_SET=1
else
  RELAY_PUBLIC_HOST="$(default_public_host)"
  RELAY_URL="ws://${RELAY_PUBLIC_HOST}:${RELAY_PORT}/relay"
fi

ensure_prerequisites
ensure_dependencies
print_host_notice

if [[ "${DRY_RUN}" -eq 1 ]]; then
  print_dry_run
  exit 0
fi

print_runtime_summary

if [[ "${RELAY_URL_WAS_SET}" -eq 0 ]]; then
  ensure_port_available
  start_embedded_relay
  wait_for_relay
  log "Relay is healthy."
else
  log "Skipping embedded relay because RELAY_URL is set."
fi

start_bridge
