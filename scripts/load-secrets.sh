#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Materialize deploy/.env from AWS SSM Parameter Store.
#
# Reads SecureString parameters under /jinx/prod/* and writes them as
# KEY=VALUE lines to stdout. Run on the EC2 host (which must have an instance
# profile granting ssm:GetParametersByPath and kms:Decrypt).
#
# Usage:
#   ./load-secrets.sh > .env && chmod 600 .env
#
# To populate SSM initially:
#   aws ssm put-parameter --type SecureString \
#     --name /jinx/prod/AUTH_ACCESS_TOKEN_SECRET --value "$(openssl rand -base64 32)"
# -----------------------------------------------------------------------------
set -euo pipefail

PREFIX="${SSM_PREFIX:-/jinx/prod}"
REGION="${AWS_REGION:-$(curl -fs --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo ap-southeast-1)}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not installed" >&2
  exit 1
fi

aws ssm get-parameters-by-path \
  --path "$PREFIX" \
  --recursive \
  --with-decryption \
  --region "$REGION" \
  --query 'Parameters[].[Name,Value]' \
  --output text |
while IFS=$'\t' read -r name value; do
  key="${name##*/}"
  # Escape any embedded double quotes in the value
  esc_value="${value//\"/\\\"}"
  printf '%s="%s"\n' "$key" "$esc_value"
done
