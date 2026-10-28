#!/usr/bin/env bash
# Restore the latest E0 backup under a new prefix, then compare bytes. WRITES: Clumio creates two
# objects in the target bucket. Run only after a go.
#   E2a (default)  same bucket, same Region: proves the data is recoverable.
#   E2c            a different Region: TARGET_BUCKET and TARGET_REGION from 12-s3-restore-sg. Proves the
#                  backup needs no source-Region key. Cross-account is E2b, a separate test.
#
#   source <path> Clumio environment file
#   scripts/restore-s3.sh                                                  # E2a
#   TARGET_BUCKET=amkcmk-restore-<acct>-ap-southeast-1 TARGET_REGION=ap-southeast-1 scripts/restore-s3.sh   # E2c
#
# The restore call is the one the kit's runner proved live (POST /restores/protection-groups).
# Needs: aws CLI (signed in), terraform, jq, curl, shasum.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars" # The one place the account and Region are set.
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="restored-$STAMP/"
MAX_WAIT_SECONDS=600 # Bounded: a restore that has not finished in 10 minutes is INCONCLUSIVE.

stop() { echo "STOP: $1" >&2; exit 1; }

# Guards: the wrong account, a missing token or a missing apply make the result meaningless.
[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || stop "lab.auto.tfvars is wrong"
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || stop "not signed in to $ACCOUNT"
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || stop "source your Clumio environment file first"
BUCKET="$(terraform -chdir="$HERE/terraform/10-s3" output -raw bucket_name 2>/dev/null)"; [ -n "$BUCKET" ] || stop "10-s3 has no bucket"
PG_ID="$(terraform -chdir="$HERE/terraform/11-s3-protect" output -raw protection_group_id 2>/dev/null)"; [ -n "$PG_ID" ] || stop "11-s3-protect not applied"

# Where to restore. The default is the source bucket and Region (E2a).
TARGET_BUCKET="${TARGET_BUCKET:-$BUCKET}"
TARGET_REGION="${TARGET_REGION:-$REGION}"
# Guards: a restore may only write into this experiment's own buckets, in the two Regions we allow.
# Singapore also holds other work, so a mistyped target must not reach it.
case "$TARGET_BUCKET" in amkcmk-*) ;; *) stop "TARGET_BUCKET '$TARGET_BUCKET' is not an amkcmk-* bucket" ;; esac
case "$TARGET_REGION" in ap-southeast-2 | ap-southeast-1) ;; *) stop "TARGET_REGION '$TARGET_REGION' is not allowed" ;; esac
[ "$TARGET_REGION" = "$REGION" ] && KIND="e2a" || KIND="e2c"
OUT="$HERE/evidence/$KIND-$STAMP"
mkdir -p "$OUT"

uri() { jq -rn --arg s "$1" '$s|@uri'; }
clumio_get() { # <path>: the token goes through curl's stdin config, never the command line.
  printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/json' "$CLUMIO_API_BASE_URL$1"
}
clumio_post() { # <path> <json body>
  printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/api.clumio.restored-protection-groups=v1+json' \
      -H 'Content-Type: application/json' -X POST -d "$2" -w '\nHTTP %{http_code}\n' "$CLUMIO_API_BASE_URL$1"
}

# 1. What to restore, and where: the latest backup of our group (the source), into the target bucket
#    and the Clumio connection of the target Region.
BACKUP_ID="$(clumio_get "/backups/protection-groups?filter=$(uri "{\"protection_group_id\":{\"\$eq\":\"$PG_ID\"}}")" \
  | jq -r '[._embedded.items[]?] | sort_by(.start_timestamp) | last | .id // empty')"
BUCKET_ID="$(clumio_get "/datasources/aws/s3-buckets?filter=$(uri "{\"name\":{\"\$in\":[\"$TARGET_BUCKET\"]}}")" \
  | jq -r --arg n "$TARGET_BUCKET" '[._embedded.items[]? | select(.name==$n)][0].id // empty')"
ENV_ID="$(clumio_get "/datasources/aws/environments?filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
  | jq -r --arg a "$ACCOUNT" --arg r "$TARGET_REGION" '[._embedded.items[]? | select(.account_native_id==$a and .aws_region==$r)][0].id // empty')"
[ -n "$BACKUP_ID" ] && [ -n "$BUCKET_ID" ] && [ -n "$ENV_ID" ] || stop "could not find backup ('$BACKUP_ID'), target bucket ('$BUCKET_ID') or target-Region connection ('$ENV_ID') in Clumio"
echo "backup=$BACKUP_ID ($REGION) -> s3://$TARGET_BUCKET/$PREFIX ($TARGET_REGION)  [$KIND]" | tee "$OUT/_request.txt"

# 2. Ask Clumio to restore. overwrite=false: it can never replace the originals.
BODY="$(jq -n --arg b "$BACKUP_ID" --arg t "$BUCKET_ID" --arg e "$ENV_ID" --arg p "$PREFIX" \
  '{source:{backup_id:$b, object_filters:{latest_version_only:true}},
    target:{bucket_id:$t, environment_id:$e, prefix:$p, overwrite:false, restore_original_storage_class:true}}')"
RESPONSE="$(clumio_post /restores/protection-groups "$BODY")"
echo "$RESPONSE" >"$OUT/restore-response.txt"
TASK_ID="$(echo "$RESPONSE" | sed '$d' | jq -r '.task_id // empty' 2>/dev/null)"
[ -n "$TASK_ID" ] || { cat "$OUT/restore-response.txt" >&2; stop "Clumio did not accept the restore. Nothing was written."; }
echo "restore task: $TASK_ID"

# 3. Wait, bounded. Only these four statuses mean finished (proven in the kit's runner).
STATUS="unknown"; WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT_SECONDS" ]; do
  STATUS="$(clumio_get "/tasks/$TASK_ID" | jq -r '.status // "unknown"')"
  case "$STATUS" in completed | failed | aborted | canceled) break ;; esac
  sleep 10; WAITED=$((WAITED + 10))
done
clumio_get "/tasks/$TASK_ID" >"$OUT/task.json"

# 4. Compare bytes with independent truth: the literal text we wrote, not a copy of what Terraform read.
EXPECTED_AMK="$(printf 'amkcmk E0 object, key: aws/s3\n' | shasum -a 256 | cut -d' ' -f1)"
EXPECTED_CMK="$(printf 'amkcmk E0 object, key: customer-managed\n' | shasum -a 256 | cut -d' ' -f1)"
RESULT=0
{
  echo "$KIND  UTC $STAMP  account $ACCOUNT  source $REGION -> target $TARGET_REGION  restore task $TASK_ID: $STATUS (waited ${WAITED}s)"
  for obj in amk cmk; do
    EXPECTED="EXPECTED_$(echo "$obj" | tr a-z A-Z)"
    if aws s3 cp "s3://$TARGET_BUCKET/${PREFIX}$obj.txt" "$OUT/restored-$obj.txt" --region "$TARGET_REGION" --only-show-errors 2>"$OUT/cp-$obj.err"; then
      GOT="$(shasum -a 256 "$OUT/restored-$obj.txt" | cut -d' ' -f1)"
    else
      GOT="missing"
    fi
    if [ "$GOT" = "${!EXPECTED}" ]; then echo "$obj.txt restored: MATCH ($GOT)"; else echo "$obj.txt restored: MISMATCH (got $GOT, expected ${!EXPECTED})"; RESULT=1; fi
    # What key did Clumio use for the restored copy? The docs are silent, so record it.
    KEY_ARN="$(aws s3api head-object --region "$TARGET_REGION" --bucket "$TARGET_BUCKET" --key "${PREFIX}$obj.txt" --query SSEKMSKeyId --output text 2>/dev/null)"
    ENC="$(aws s3api head-object --region "$TARGET_REGION" --bucket "$TARGET_BUCKET" --key "${PREFIX}$obj.txt" --query ServerSideEncryption --output text 2>/dev/null)"
    MGR="none"; [ -n "$KEY_ARN" ] && [ "$KEY_ARN" != "None" ] && MGR="$(aws kms describe-key --region "$TARGET_REGION" --key-id "$KEY_ARN" --query KeyMetadata.KeyManager --output text 2>/dev/null)"
    echo "$obj.txt restored copy is encrypted with: ${ENC:-?}, key manager: $MGR"
  done
  [ "$STATUS" = "completed" ] || RESULT=1
  [ "$RESULT" = 0 ] && echo "$KIND: PASS" || echo "$KIND: NOT PASSED (see above; a non-completed status is INCONCLUSIVE or FAILED, not a pass)"
} | tee "$OUT/_summary.txt"

( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
echo "Saved: $OUT"
exit "$RESULT"
