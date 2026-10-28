#!/usr/bin/env bash
# Result of the guard test (E3). READ-ONLY. Run it after Clumio's next daily backup of the protection group.
#
#   source your Clumio environment file (CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL)
#   scripts/check-guard.sh          writes evidence/guard-<UTC time>/
#
# It reads AWS (the keys, the objects, the key policies, CloudTrail) and the Clumio backup records.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars"
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
OUT="$HERE/evidence/guard-$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT/_calls.log"

[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || { echo "STOP: lab.auto.tfvars is wrong" >&2; exit 1; }
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || { echo "STOP: not signed in to $ACCOUNT" >&2; exit 1; }
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || { echo "STOP: set CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL first" >&2; exit 1; }
BUCKET="$(terraform -chdir="$HERE/terraform/10-s3" output -raw bucket_name 2>/dev/null)"
PG_ID="$(terraform -chdir="$HERE/terraform/15-s3-guard-protect" output -raw protection_group_id 2>/dev/null)" # the group created for this test
HARD="$(terraform -chdir="$HERE/terraform/14-s3-guard" output -raw hardened_key_arn 2>/dev/null)"
DENY="$(terraform -chdir="$HERE/terraform/14-s3-guard" output -raw denied_key_arn 2>/dev/null)"
[ -n "$BUCKET" ] && [ -n "$PG_ID" ] && [ -n "$HARD" ] && [ -n "$DENY" ] || { echo "STOP: 10-s3, 14-s3-guard and 15-s3-guard-protect must be applied" >&2; exit 1; }
mkdir -p "$OUT"

aws_save() { local f="$1"; shift; "$@" >"$OUT/$f" 2>&1; echo "aws    exit=$?  $f" >>"$LOG"; }
clumio_save() { local f="$1" p="$2" c
  c="$(printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" | curl -sS -m 30 --config - -H 'Accept: application/json' -o "$OUT/$f" -w '%{http_code}' "$CLUMIO_API_BASE_URL$p")"
  echo "clumio http=$c  $f" >>"$LOG"; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }

date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/utc-time.txt"
# 1. The two keys and the policies AWS holds for them (raw).
for k in hardened denied; do
  arn="$HARD"; [ "$k" = denied ] && arn="$DENY"
  aws_save "describe-key-$k.json" aws kms describe-key --key-id "$arn"
  aws_save "key-policy-$k.json" aws kms get-key-policy --key-id "${arn##*/}" --policy-name default --query Policy --output text
done
for o in allowed denied; do aws_save "head-$o.json" aws s3api head-object --bucket "$BUCKET" --key "$o.txt"; done
# 2. CloudTrail: what Clumio's role did with each key. A failed call is recorded with an errorCode.
for ev in Decrypt; do
  aws_save "cloudtrail-$ev.json" aws cloudtrail lookup-events --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" \
    --start-time "$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ)" --max-results 50 --query 'Events[].CloudTrailEvent'
done
# 3. Clumio: the backups of the group, newest first.
clumio_save backups.json "/backups/protection-groups?filter=$(uri "{\"protection_group_id\":{\"\$eq\":\"$PG_ID\"}}")"

{
  echo "UTC $(cat "$OUT/utc-time.txt")  bucket $BUCKET"
  for o in allowed denied; do
    echo "$o.txt is encrypted with key $(jq -r '.SSEKMSKeyId|sub(".*key/";"")|.[0:8]' "$OUT/head-$o.json" 2>/dev/null)"
  done
  echo
  echo "KMS Decrypt calls by Clumio's role on the two keys (last 30h; errorCode shows a refused call):"
  jq -r --arg h "${HARD##*/}" --arg d "${DENY##*/}" '.[]? | fromjson | select((.userIdentity.arn // "")|contains("ClumioIAMRole"))
    | select((.resources[0].ARN // "")|(contains($h) or contains($d)))
    | "  \(.eventTime[11:19]) \((.resources[0].ARN|sub(".*key/";"")|.[0:8])) \(if (.resources[0].ARN|contains($h)) then "hardened" else "denied  " end)  \(.errorCode // "SUCCESS")"' "$OUT/cloudtrail-Decrypt.json" 2>/dev/null | sort
  echo
  echo "Clumio backups of the group (newest first): start | backed up / failed / missing objects"
  jq -r '[._embedded.items[]?] | sort_by(.start_timestamp) | reverse | .[0:4][] | "  \(.start_timestamp[0:16]) | \(.backed_up_object_count) / \(.failed_object_count) / \(.missing_object_count)"' "$OUT/backups.json" 2>/dev/null
  echo
  echo "Calls that did not succeed:"; grep -vE 'exit=0|http=200' "$LOG" || echo "  none"
} >"$OUT/_summary.txt"
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
cat "$OUT/_summary.txt"; echo "Saved: $OUT"
