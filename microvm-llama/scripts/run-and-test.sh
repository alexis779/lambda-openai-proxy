#!/usr/bin/env bash
# Run + test against an already-built MicroVM image (skips package/build).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
REGION="${AWS_REGION:-us-west-2}"
STACK_NAME="${STACK_NAME:-llama-microvm}"
IMAGE_NAME="${IMAGE_NAME:-llama-minicpm-server}"
PROMPT_TEXT="${PROMPT_TEXT:-How can I loose weight ?}"

cfn_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text
}

EXEC_ROLE_ARN="$(cfn_output MicroVmExecutionRoleArn)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:microvm-image:${IMAGE_NAME}"
EGRESS_ARN="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
INGRESS_ARN="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"

echo "==> Run MicroVM from ${IMAGE_ARN}"
RUN_JSON="$(aws lambda-microvms run-microvm \
  --region "${REGION}" \
  --image-identifier "${IMAGE_ARN}" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --ingress-network-connectors "${INGRESS_ARN}" \
  --egress-network-connectors "${EGRESS_ARN}" \
  --idle-policy '{"autoResumeEnabled":true,"maxIdleDurationSeconds":900,"suspendedDurationSeconds":300}' \
  --maximum-duration-in-seconds 3600 \
  --output json)"

MICROVM_ID="$(echo "${RUN_JSON}" | jq -r '.microvmId')"
ENDPOINT="$(echo "${RUN_JSON}" | jq -r '.endpoint')"
echo "MicroVM=${MICROVM_ID}"
echo "Endpoint=${ENDPOINT}"

cleanup_mvm() {
  if [[ -n "${MICROVM_ID:-}" ]]; then
    echo "==> Terminating MicroVM ${MICROVM_ID}"
    aws lambda-microvms terminate-microvm \
      --region "${REGION}" \
      --microvm-identifier "${MICROVM_ID}" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup_mvm EXIT

while true; do
  state="$(aws lambda-microvms get-microvm \
    --region "${REGION}" \
    --microvm-identifier "${MICROVM_ID}" \
    --query 'state' \
    --output text)"
  echo "  microvm state=${state}"
  case "${state}" in
    RUNNING) break ;;
    TERMINATED|TERMINATING|FAILED)
      echo "MicroVM entered terminal state: ${state}" >&2
      exit 1
      ;;
  esac
  sleep 5
done

TOKEN="$(aws lambda-microvms create-microvm-auth-token \
  --region "${REGION}" \
  --microvm-identifier "${MICROVM_ID}" \
  --expiration-in-minutes 60 \
  --allowed-ports '[{"port":8080}]' \
  --query 'authToken' \
  --output text)"

BODY="$(jq -n \
  --arg content "${PROMPT_TEXT}" \
  '{
    model: "openbmb/MiniCPM5-1B-GGUF:Q4_K_M",
    messages: [{role: "user", content: $content}],
    max_tokens: 512,
    temperature: 0.7
  }')"

RESP_FILE="$(mktemp)"
HTTP_CODE="$(curl -sS -o "${RESP_FILE}" -w "%{http_code}" \
  "https://${ENDPOINT}/v1/chat/completions" \
  -H "X-aws-proxy-auth: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BODY}")"

echo "HTTP ${HTTP_CODE}"
cat "${RESP_FILE}"
echo

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Chat completion request failed" >&2
  exit 1
fi

REPLY="$(jq -r '.choices[0].message.content // empty' "${RESP_FILE}")"
if [[ -z "${REPLY}" ]]; then
  REPLY="$(jq -r '.choices[0].message.reasoning_content // empty' "${RESP_FILE}")"
fi
if [[ -z "${REPLY}" ]]; then
  echo "Response missing choices[0].message.content (and reasoning_content)" >&2
  exit 1
fi

echo "==> Model reply:"
echo "${REPLY}"
echo "==> Success"
