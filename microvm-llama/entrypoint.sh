#!/usr/bin/env bash
set -euo pipefail

export HOOKS_PORT="${HOOKS_PORT:-8090}"
export LLAMA_PORT="${LLAMA_PORT:-8080}"
export LLAMA_HEALTH_URL="${LLAMA_HEALTH_URL:-http://127.0.0.1:${LLAMA_PORT}/health}"
export LLAMA_HF_REPO="${LLAMA_HF_REPO:-openbmb/MiniCPM5-1B-GGUF:Q4_K_M}"
export LLAMA_THREADS="${LLAMA_THREADS:-16}"
export LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-2048}"

LLAMA_BIN="${LLAMA_BIN:-/opt/llama.cpp/llama-server}"

echo "[entrypoint] starting hooks server on :${HOOKS_PORT}"
python3 /opt/hooks_server.py &
HOOKS_PID=$!

cleanup() {
  echo "[entrypoint] shutting down"
  kill "${HOOKS_PID}" 2>/dev/null || true
  if [[ -n "${LLAMA_PID:-}" ]]; then
    kill "${LLAMA_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[entrypoint] starting llama-server (${LLAMA_HF_REPO}) threads=${LLAMA_THREADS} ctx=${LLAMA_CTX_SIZE}"
"${LLAMA_BIN}" \
  -hf "${LLAMA_HF_REPO}" \
  -t "${LLAMA_THREADS}" \
  -c "${LLAMA_CTX_SIZE}" \
  --host 0.0.0.0 \
  --port "${LLAMA_PORT}" &
LLAMA_PID=$!

wait "${LLAMA_PID}"
