#!/usr/bin/env bash
set -euo pipefail
cd /Users/linhey/Desktop/Dockers/remodex
REMODEX_ENV_FILE=/Users/linhey/Desktop/Dockers/remodex/.env.local ./run-local-remodex.sh "$@"
