#!/usr/bin/env bash
# Run AWS CLI in Docker against ~/.aws (SSO login, sts, etc.).
# Usage:
#   ./scripts/aws.sh sso login --use-device-code --profile YOUR_DEST_PROFILE
#   ./scripts/aws.sh sts get-caller-identity --profile YOUR_DEST_PROFILE
#
# Override image with AWS_CLI_IMAGE (default amazon/aws-cli:latest).
set -euo pipefail

AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-amazon/aws-cli:latest}"

usage() {
  cat >&2 <<EOF
Usage: $0 <aws cli args...>

Authenticate and verify with the official AWS CLI image (no local aws install).

Examples:
  $0 sso login --use-device-code --profile YOUR_DEST_PROFILE
  $0 sso login --use-device-code --profile YOUR_SOURCE_PROFILE
  $0 sts get-caller-identity --profile YOUR_DEST_PROFILE
  $0 configure --profile YOUR_DEST_PROFILE
EOF
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

mkdir -p "${HOME}/.aws"

DOCKER_ARGS=(
  --rm
  --user "$(id -u):$(id -g)"
  -e HOME=/aws
  -e AWS_SDK_LOAD_CONFIG=1
  -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials
  -e AWS_CONFIG_FILE=/aws/config
  -v "${HOME}/.aws":/aws
)

if [[ -t 0 ]]; then
  DOCKER_ARGS+=(-it)
fi

pass_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    DOCKER_ARGS+=(-e "$name")
  fi
}

pass_env AWS_PROFILE
pass_env AWS_ACCESS_KEY_ID
pass_env AWS_SECRET_ACCESS_KEY
pass_env AWS_SESSION_TOKEN
pass_env AWS_REGION
pass_env AWS_DEFAULT_REGION

exec docker run "${DOCKER_ARGS[@]}" "$AWS_CLI_IMAGE" "$@"
