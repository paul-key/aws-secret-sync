#!/usr/bin/env bash
# Run OpenTofu (Terraform-compatible) in Docker against terraform/dest or terraform/source.
# Default image uses registry.opentofu.org because registry.terraform.io is geo-blocked
# in some countries. Override with TF_IMAGE=hashicorp/terraform:1.9 if you can reach HashiCorp.
# Usage:
#   ./scripts/tf.sh dest <aws-profile> init
#   ./scripts/tf.sh dest <aws-profile> apply
#   ./scripts/tf.sh source <aws-profile> output writer_role_arn
#   AWS_PROFILE=dest ./scripts/tf.sh dest apply
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_IMAGE="${TF_IMAGE:-ghcr.io/opentofu/opentofu:1.9}"

TF_COMMANDS="init apply plan output destroy validate fmt show refresh import state console workspace force-unlock graph providers version test"

usage() {
  cat >&2 <<EOF
Usage: $0 <dest|source> [aws-profile] <terraform args...>

  dest|source     Terraform root (terraform/dest or terraform/source)
  aws-profile     Named profile from ~/.aws (optional if AWS_PROFILE or access keys are set)

Examples:
  $0 dest my-dest-profile init
  $0 dest my-dest-profile apply
  $0 dest my-dest-profile output writer_role_arn
  $0 source my-source-profile apply
  AWS_PROFILE=dest $0 dest plan
EOF
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

STACK="${1:-}"
shift || true

case "$STACK" in
  dest | terraform/dest) WORKDIR="terraform/dest" ;;
  source | terraform/source) WORKDIR="terraform/source" ;;
  *) usage ;;
esac

if [[ $# -gt 0 && "$1" != -* && " $TF_COMMANDS " != *" $1 "* ]]; then
  AWS_PROFILE="$1"
  export AWS_PROFILE
  shift
fi

if [[ $# -eq 0 ]]; then
  usage
fi

DOCKER_ARGS=(
  --rm
  --user "$(id -u):$(id -g)"
  -e HOME=/tmp
  -e AWS_SDK_LOAD_CONFIG=1
  -v "$ROOT":/workspace
  -w "/workspace/$WORKDIR"
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

if [[ -d "${HOME}/.aws" ]]; then
  DOCKER_ARGS+=(
    -e HOME=/aws
    -e AWS_SHARED_CREDENTIALS_FILE=/aws/credentials
    -e AWS_CONFIG_FILE=/aws/config
    -v "${HOME}/.aws":/aws:ro
  )
fi

exec docker run "${DOCKER_ARGS[@]}" "$TF_IMAGE" "$@"
