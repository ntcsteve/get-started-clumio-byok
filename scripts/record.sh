#!/usr/bin/env bash
# Evidence capture for experiment E0 (S3). READ-ONLY: it changes nothing in AWS or Clumio.
# Saves raw output, then a short summary, so the conclusion can be re-checked by someone who was not here.
#
#   source <path> Clumio environment file
#   scripts/record.sh s3            writes evidence/s3-<UTC time>/
#
# Needs: aws CLI (signed in), terraform, jq, curl, shasum, CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL.
set -uo pipefail # No -e: one failed call must not stop the others. Each call's result is logged.

[ "${1:-}" = "s3" ] || { echo "usage: scripts/record.sh s3" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars" # The one place the account and Region are set.
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
OUT="$HERE/evidence/s3-$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT/_calls.log"

# Guards: the wrong account, a missing token or a missing apply make every file below meaningless.
[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || { echo "STOP: lab.auto.tfvars is wrong" >&2; exit 1; }
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || { echo "STOP: not signed in to $ACCOUNT" >&2; exit 1; }
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || { echo "STOP: source your Clumio environment file first" >&2; exit 1; }
BUCKET="$(terraform -chdir="$HERE/terraform/10-s3" output -raw bucket_name 2>/dev/null)"
[ -n "$BUCKET" ] || { echo "STOP: 10-s3 has no bucket. Has it been applied?" >&2; exit 1; }
PG_ID="$(terraform -chdir="$HERE/terraform/11-s3-protect" output -raw protection_group_id 2>/dev/null)"
[ -n "$PG_ID" ] || echo "NOTE: 11-s3-protect not applied yet; Clumio backups will not be captured." >&2
mkdir -p "$OUT"

# aws_save <file> <command...>: run a read-only AWS call, keep its output, log the exit code.
aws_save() {
  local file="$1"; shift
  "$@" >"$OUT/$file" 2>&1; echo "aws    exit=$?  $file" >>"$LOG"
}

# clumio_save <file> <path>: GET from Clumio. The token goes through curl's stdin config, never the command line.
clumio_save() {
  local file="$1" path="$2" code
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/json' -o "$OUT/$file" -w '%{http_code}' "$CLUMIO_API_BASE_URL$path")"
  echo "clumio http=$code  $file" >>"$LOG"
}
uri() { jq -rn --arg s "$1" '$s|@uri'; }

date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/utc-time.txt"

# 1. Which key does each object really use, and is that key AWS-managed or customer-managed?
for obj in amk cmk; do
  aws_save "head-$obj.json" aws s3api head-object --bucket "$BUCKET" --key "$obj.txt"
  KEY_ARN="$(jq -r '.SSEKMSKeyId // empty' "$OUT/head-$obj.json" 2>/dev/null)"
  [ -n "$KEY_ARN" ] && aws_save "key-$obj.json" aws kms describe-key --key-id "$KEY_ARN" \
    --query 'KeyMetadata.{Arn:Arn,KeyManager:KeyManager,KeyState:KeyState}'
  # For skeptics: the full describe-key response (the file above is a summary), the alias, the tags, and the AWS-managed key's policy.
  [ -n "$KEY_ARN" ] && aws_save "key-full-$obj.json" aws kms describe-key --key-id "$KEY_ARN"
  [ -n "$KEY_ARN" ] && aws_save "alias-$obj.json" aws kms list-aliases --key-id "$KEY_ARN" --query 'Aliases[].AliasName'
  [ -n "$KEY_ARN" ] && aws_save "tags-$obj.json" aws kms list-resource-tags --key-id "$KEY_ARN" --query 'Tags'
  # An alias is not accepted here, so the policy is read by key id.
  [ "$(jq -r '.KeyManager // empty' "$OUT/key-$obj.json" 2>/dev/null)" = "AWS" ] && \
    aws_save "policy-aws-managed-key.json" aws kms get-key-policy --key-id "${KEY_ARN##*/}" --policy-name default --query Policy --output text
done

# 2. What did Clumio do? Is the bucket in its inventory, its backups of the group, and its tasks.
clumio_save buckets.json "/datasources/aws/s3-buckets?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")"
if [ -n "$PG_ID" ]; then
  clumio_save backups.json "/backups/protection-groups?filter=$(uri "{\"protection_group_id\":{\"\$eq\":\"$PG_ID\"}}")"
  clumio_save tasks.json "/tasks?limit=50&filter=$(uri '{"primary_entity.value":{"$contains":"amkcmk"}}')"
fi

# 3. A short summary. SETUP must say OK before any backup result means anything.
{
  echo "UTC $(cat "$OUT/utc-time.txt")  account $ACCOUNT  region $REGION  bucket $BUCKET"
  AMK_MGR="$(jq -r '.KeyManager // "?"' "$OUT/key-amk.json" 2>/dev/null)"
  CMK_MGR="$(jq -r '.KeyManager // "?"' "$OUT/key-cmk.json" 2>/dev/null)"
  echo "amk.txt key manager: $AMK_MGR   (must be AWS)  alias: $(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/alias-amk.json" 2>/dev/null)"
  echo "cmk.txt key manager: $CMK_MGR   (must be CUSTOMER)  alias: $(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/alias-cmk.json" 2>/dev/null)  tag exp=$(jq -r '[.[]? | select(.TagKey=="exp") | .TagValue] | if length==0 then "none" else .[0] end' "$OUT/tags-cmk.json" 2>/dev/null)"
  if [ "$AMK_MGR" = "AWS" ] && [ "$CMK_MGR" = "CUSTOMER" ]; then echo "SETUP: OK"; else echo "SETUP: WRONG, the experiment is invalid"; fi
  echo "bucket seen by Clumio: $(jq -r --arg b "$BUCKET" '[._embedded.items[]? | select(.name==$b)] | length' "$OUT/buckets.json" 2>/dev/null || echo '?') (must be 1 before protecting; 0 is expected until 00-connect is applied)"
  [ -n "$PG_ID" ] && echo "Clumio backups of the group: $(jq -r '._embedded.items | length' "$OUT/backups.json" 2>/dev/null || echo '?')"
  [ -n "$PG_ID" ] && echo "Clumio tasks (statuses): $(jq -r '[._embedded.items[]?.status] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' "$OUT/tasks.json" 2>/dev/null || echo '?')"
  echo "Calls that did not succeed:"; grep -vE 'exit=0|http=200' "$LOG" || echo "  none"
} >"$OUT/_summary.txt"

# 4. Fingerprint every file, so later edits are visible.
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )

cat "$OUT/_summary.txt"
echo "Saved: $OUT"
echo "A call listed above as not successful means that file is an error, not evidence."
