#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
REGION="${AWS_REGION:-us-west-2}"
STACK_NAME="${STACK_NAME:-llama-microvm}"
PROJECT_NAME="${PROJECT_NAME:-llama-microvm}"
IMAGE_NAME="${IMAGE_NAME:-llama-minicpm-server}"
ARTIFACT_KEY="${ARTIFACT_KEY:-llama-microvm.zip}"
PROMPT_TEXT="${PROMPT_TEXT:-How can I loose weight ?}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_aws_cli_microvms() {
  if aws lambda-microvms help >/dev/null 2>&1; then
    echo "AWS CLI already supports lambda-microvms"
    return
  fi

  echo "Upgrading AWS CLI so lambda-microvms is available..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo "${tmp}/aws/install" --update
  else
    "${tmp}/aws/install" --update --bin-dir "${HOME}/.local/bin" --install-dir "${HOME}/.local/aws-cli"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  rm -rf "${tmp}"

  if ! aws lambda-microvms help >/dev/null 2>&1; then
    echo "AWS CLI upgrade finished but lambda-microvms is still unavailable." >&2
    aws --version >&2
    exit 1
  fi
  aws --version
}

cfn_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text
}

wait_image_ready() {
  local image_id="$1"
  local state=""
  echo "Waiting for MicroVM image ${image_id} to become CREATED..."
  while true; do
    local json
    json="$(aws lambda-microvms get-microvm-image \
      --region "${REGION}" \
      --image-identifier "${image_id}" \
      --output json 2>/dev/null || true)"
    if [[ -z "${json}" ]]; then
      echo "  image not found yet"
      sleep 20
      continue
    fi
    state="$(echo "${json}" | jq -r '.state // empty')"
    echo "  image state=${state}"
    if [[ "${state}" == "CREATING" || "${state}" == "UPDATING" ]]; then
      local builds
      builds="$(aws lambda-microvms list-microvm-image-builds \
        --region "${REGION}" \
        --image-identifier "${image_id}" \
        --image-version "$(echo "${json}" | jq -r '.imageVersion // .latestFailedImageVersion // "1.0"')" \
        --output json 2>/dev/null || echo '{"items":[]}')"
      echo "${builds}" | jq -r '.items[]? | "    build \(.buildId) arch=\(.architecture) chipset=\(.chipset)\(.chipsetGeneration) state=\(.buildState) reason=\(.stateReason // "-")"' 2>/dev/null || true
    fi
    case "${state}" in
      CREATED|UPDATED) return 0 ;;
      CREATE_FAILED|UPDATE_FAILED|DELETED|DELETION_FAILED)
        echo "MicroVM image entered terminal failure state: ${state}" >&2
        echo "${json}" | jq . >&2 || true
        local ver
        ver="$(echo "${json}" | jq -r '.latestFailedImageVersion // .imageVersion // "1.0"')"
        aws lambda-microvms list-microvm-image-builds \
          --region "${REGION}" \
          --image-identifier "${image_id}" \
          --image-version "${ver}" \
          --output json >&2 || true
        return 1
        ;;
    esac
    sleep 30
  done
}

wait_microvm_running() {
  local mvm_id="$1"
  local state=""
  echo "Waiting for MicroVM ${mvm_id} to become RUNNING..."
  while true; do
    state="$(aws lambda-microvms get-microvm \
      --region "${REGION}" \
      --microvm-identifier "${mvm_id}" \
      --query 'state' \
      --output text)"
    echo "  microvm state=${state}"
    case "${state}" in
      RUNNING) return 0 ;;
      TERMINATED|TERMINATING|FAILED)
        echo "MicroVM entered terminal state: ${state}" >&2
        aws lambda-microvms get-microvm \
          --region "${REGION}" \
          --microvm-identifier "${mvm_id}" \
          --output json >&2 || true
        return 1
        ;;
    esac
    sleep 10
  done
}

need_cmd aws
need_cmd curl
need_cmd zip
need_cmd python3
need_cmd jq

ensure_aws_cli_microvms

echo "==> Deploy bucket + IAM (DeployImage=false; image built via CLI for long builds)"
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file "${ROOT_DIR}/template.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "ImageName=${IMAGE_NAME}" \
    "ArtifactObjectKey=${ARTIFACT_KEY}" \
    "DeployImage=false"

BUCKET="$(cfn_output ArtifactBucketName)"
BUILD_ROLE_ARN="$(cfn_output BuildRoleArn)"
EXEC_ROLE_ARN="$(cfn_output MicroVmExecutionRoleArn)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:microvm-image:${IMAGE_NAME}"
BASE_IMAGE_ARN="arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1"
EGRESS_ARN="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
INGRESS_ARN="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"

echo "Bucket=${BUCKET}"
echo "BuildRole=${BUILD_ROLE_ARN}"
echo "ExecutionRole=${EXEC_ROLE_ARN}"
echo "ImageArn=${IMAGE_ARN}"

echo "==> Package + upload artifact"
bash "${ROOT_DIR}/scripts/package.sh" "${ROOT_DIR}/llama-microvm.zip"
aws s3 cp "${ROOT_DIR}/llama-microvm.zip" "s3://${BUCKET}/${ARTIFACT_KEY}" --region "${REGION}"

EXISTING_STATE="$(aws lambda-microvms get-microvm-image \
  --region "${REGION}" \
  --image-identifier "${IMAGE_ARN}" \
  --query 'state' \
  --output text 2>/dev/null || echo "MISSING")"

if [[ "${EXISTING_STATE}" == "CREATE_FAILED" || "${EXISTING_STATE}" == "UPDATE_FAILED" ]]; then
  echo "==> Deleting failed MicroVM image ${IMAGE_NAME} (state=${EXISTING_STATE})"
  aws lambda-microvms delete-microvm-image \
    --region "${REGION}" \
    --image-identifier "${IMAGE_ARN}" \
    >/dev/null
  for _ in $(seq 1 60); do
    cur="$(aws lambda-microvms get-microvm-image \
      --region "${REGION}" \
      --image-identifier "${IMAGE_ARN}" \
      --query 'state' \
      --output text 2>/dev/null || echo "MISSING")"
    [[ "${cur}" == "MISSING" || "${cur}" == "DELETED" ]] && break
    echo "  waiting for delete (state=${cur})"
    sleep 5
  done
  EXISTING_STATE="MISSING"
fi

if [[ "${EXISTING_STATE}" == "CREATED" || "${EXISTING_STATE}" == "UPDATED" ]]; then
  echo "==> Updating existing MicroVM image ${IMAGE_NAME}"
  aws lambda-microvms update-microvm-image \
    --region "${REGION}" \
    --image-identifier "${IMAGE_ARN}" \
    --code-artifact "uri=s3://${BUCKET}/${ARTIFACT_KEY}" \
    --base-image-arn "${BASE_IMAGE_ARN}" \
    --base-image-version "0" \
    --build-role-arn "${BUILD_ROLE_ARN}" \
    --description "llama.cpp server with MiniCPM5-1B GGUF (Q4_K_M)" \
    --additional-os-capabilities ALL \
    --cpu-configurations '[{"architecture":"ARM_64"}]' \
    --resources '[{"minimumMemoryInMiB":8192}]' \
    --egress-network-connectors "${EGRESS_ARN}" \
    --environment-variables '{"LLAMA_HF_REPO":"openbmb/MiniCPM5-1B-GGUF:Q4_K_M","LLAMA_THREADS":"16","LLAMA_CTX_SIZE":"2048"}' \
    --hooks '{"port":8090,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":3600,"validate":"ENABLED","validateTimeoutInSeconds":600},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":30,"resume":"ENABLED","resumeTimeoutInSeconds":30,"suspend":"ENABLED","suspendTimeoutInSeconds":30,"terminate":"ENABLED","terminateTimeoutInSeconds":30}}' \
    --logging '{"cloudWatch":{}}'
else
  echo "==> Creating MicroVM image ${IMAGE_NAME} via CLI"
  aws lambda-microvms create-microvm-image \
    --region "${REGION}" \
    --name "${IMAGE_NAME}" \
    --code-artifact "uri=s3://${BUCKET}/${ARTIFACT_KEY}" \
    --base-image-arn "${BASE_IMAGE_ARN}" \
    --base-image-version "0" \
    --build-role-arn "${BUILD_ROLE_ARN}" \
    --description "llama.cpp server with MiniCPM5-1B GGUF (Q4_K_M)" \
    --additional-os-capabilities ALL \
    --cpu-configurations '[{"architecture":"ARM_64"}]' \
    --resources '[{"minimumMemoryInMiB":8192}]' \
    --egress-network-connectors "${EGRESS_ARN}" \
    --environment-variables '{"LLAMA_HF_REPO":"openbmb/MiniCPM5-1B-GGUF:Q4_K_M","LLAMA_THREADS":"16","LLAMA_CTX_SIZE":"2048"}' \
    --hooks '{"port":8090,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":3600,"validate":"ENABLED","validateTimeoutInSeconds":600},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":30,"resume":"ENABLED","resumeTimeoutInSeconds":30,"suspend":"ENABLED","suspendTimeoutInSeconds":30,"terminate":"ENABLED","terminateTimeoutInSeconds":30}}' \
    --logging '{"cloudWatch":{}}'
fi

wait_image_ready "${IMAGE_ARN}"

echo "==> Run MicroVM"
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

wait_microvm_running "${MICROVM_ID}"

echo "==> Create auth token"
TOKEN="$(aws lambda-microvms create-microvm-auth-token \
  --region "${REGION}" \
  --microvm-identifier "${MICROVM_ID}" \
  --expiration-in-minutes 60 \
  --allowed-ports '[{"port":8080}]' \
  --query 'authToken' \
  --output text)"

echo "==> Send chat completion prompt"
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
