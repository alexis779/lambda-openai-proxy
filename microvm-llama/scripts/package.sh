#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ZIP="${1:-${ROOT_DIR}/llama-microvm.zip}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cp "${ROOT_DIR}/Dockerfile" "${TMP_DIR}/"
cp "${ROOT_DIR}/entrypoint.sh" "${TMP_DIR}/"
cp "${ROOT_DIR}/hooks_server.py" "${TMP_DIR}/"
chmod +x "${TMP_DIR}/entrypoint.sh"

rm -f "${OUT_ZIP}"
(
  cd "${TMP_DIR}"
  zip -q "${OUT_ZIP}" Dockerfile entrypoint.sh hooks_server.py
)

echo "Wrote ${OUT_ZIP}"
ls -lh "${OUT_ZIP}"
