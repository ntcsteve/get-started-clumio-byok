#!/usr/bin/env bash
# Evidence capture for experiment E1 (RDS). READ-ONLY: it changes nothing in AWS or Clumio.
# Saves raw output, then a short summary, so the conclusion can be re-checked by someone who was not here.
#
#   source <path> Clumio environment file
#   scripts/record-rds.sh           writes evidence/rds-<UTC time>/
#
# Needs: aws CLI (signed in), terraform, jq, curl, shasum, CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL.
set -uo pipefail # No -e: one failed call must not stop the others. Each call's result is logged.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars" # The one place the account and Region are set.
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
OUT="$HERE/evidence/rds-$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT/_calls.log"

# Guards: the wrong account, a missing token or a missing apply make every file below meaningless.
[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || { echo "STOP: lab.auto.tfvars is wrong" >&2; exit 1; }
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || { echo "STOP: not signed in to $ACCOUNT" >&2; exit 1; }
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || { echo "STOP: source your Clumio environment file first" >&2; exit 1; }
DBS="$(terraform -chdir="$HERE/terraform/20-rds" output -json db_identifiers 2>/dev/null | jq -r '.[]?')"
[ -n "$DBS" ] || { echo "STOP: 20-rds has no databases. Has it been applied?" >&2; exit 1; }
POLICY_ID="$(terraform -chdir="$HERE/terraform/21-rds-protect" output -raw policy_id 2>/dev/null)"
[ -n "$POLICY_ID" ] || echo "NOTE: 21-rds-protect not applied yet; Clumio protection will not be captured." >&2
mkdir -p "$OUT"

aws_save() { # <file> <command...>: run a read-only AWS call, keep its output, log the exit code.
  local file="$1"; shift
  "$@" >"$OUT/$file" 2>&1; echo "aws    exit=$?  $file" >>"$LOG"
}
clumio_save() { # <file> <path>: GET from Clumio. The token goes through curl's stdin config, never the command line.
  local file="$1" path="$2" code
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/json' -o "$OUT/$file" -w '%{http_code}' "$CLUMIO_API_BASE_URL$path")"
  echo "clumio http=$code  $file" >>"$LOG"
}
uri() { jq -rn --arg s "$1" '$s|@uri'; }

date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/utc-time.txt"

# 1. What key does each database really use, and is it AWS-managed or customer-managed?
for db in $DBS; do
  aws_save "db-$db.json" aws rds describe-db-instances --db-instance-identifier "$db" \
    --query 'DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Encrypted:StorageEncrypted,KmsKeyId:KmsKeyId,BackupRetention:BackupRetentionPeriod}'
  KEY_ARN="$(jq -r '.KmsKeyId // empty' "$OUT/db-$db.json" 2>/dev/null)"
  [ -n "$KEY_ARN" ] && aws_save "key-$db.json" aws kms describe-key --key-id "$KEY_ARN" \
    --query 'KeyMetadata.{Arn:Arn,KeyManager:KeyManager,KeyState:KeyState}'
done

# 1b. For skeptics: AWS's own words on each key (alias, tags), the AWS-managed key's policy, and every
#     snapshot Clumio made with the key it is encrypted with and who it is shared with.
AMK_KEY_ID=""
for db in $DBS; do
  KEY_ARN="$(jq -r '.KmsKeyId // empty' "$OUT/db-$db.json" 2>/dev/null)"
  [ -n "$KEY_ARN" ] || continue
  aws_save "key-full-$db.json" aws kms describe-key --key-id "$KEY_ARN" # the whole response; key-$db.json is a summary
  aws_save "alias-$db.json" aws kms list-aliases --key-id "$KEY_ARN" --query 'Aliases[].AliasName'
  aws_save "tags-$db.json" aws kms list-resource-tags --key-id "$KEY_ARN" --query 'Tags'
  [ "$(jq -r '.KeyManager // empty' "$OUT/key-$db.json" 2>/dev/null)" = "AWS" ] && AMK_KEY_ID="${KEY_ARN##*/}"
done
# An alias is not accepted here, so the policy is read by key id.
[ -n "$AMK_KEY_ID" ] && aws_save "policy-aws-managed-key.json" aws kms get-key-policy --key-id "$AMK_KEY_ID" --policy-name default --query Policy --output text
aws_save snapshots.json aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].{Snapshot:DBSnapshotIdentifier,Database:DBInstanceIdentifier,Status:Status,Percent:PercentProgress,Encrypted:Encrypted,Key:KmsKeyId}'
for snap in $(jq -r '.[]?.Snapshot' "$OUT/snapshots.json" 2>/dev/null); do
  aws_save "snapshot-shared-$snap.json" aws rds describe-db-snapshot-attributes --db-snapshot-identifier "$snap" \
    --query 'DBSnapshotAttributesResult.DBSnapshotAttributes'
done

# 1c. CloudTrail: who made each snapshot call in our account. Clumio deletes its temporary snapshots, so
#     without the audit log the "Clumio re-encrypts a copy and shares only that" claim would have nothing
#     left to point at. Management events stay in Event history for 90 days; the last 24 hours are captured.
CT_START="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
for ev in CreateDBSnapshot CopyDBSnapshot ModifyDBSnapshotAttribute DeleteDBSnapshot; do
  aws_save "cloudtrail-$ev.json" aws cloudtrail lookup-events --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" \
    --start-time "$CT_START" --max-results 50 --query 'Events[].CloudTrailEvent'
done

# 2. What did Clumio do? Does it see the databases, which policy do they have, and what backups exist?
clumio_save rds-resources.json "/datasources/aws/rds-resources?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")"
for db in $DBS; do
  RID="$(jq -r --arg n "$db" --arg r "$REGION" '[._embedded.items[]? | select(.name==$n and .aws_region==$r and .is_deleted==false)][0].id // empty' "$OUT/rds-resources.json" 2>/dev/null)"
  echo "$RID" >"$OUT/clumio-id-$db.txt"
  [ -n "$RID" ] && clumio_save "backups-$db.json" "/backups/aws/rds-resources?filter=$(uri "{\"resource_id\":{\"\$eq\":\"$RID\"}}")"
done
[ -n "$POLICY_ID" ] && clumio_save tasks.json "/tasks?limit=50&filter=$(uri '{"primary_entity.value":{"$contains":"amkcmk-rds"}}')"

# 3. A short summary. SETUP must say OK before any backup result means anything.
{
  echo "UTC $(cat "$OUT/utc-time.txt")  account $ACCOUNT  region $REGION"
  SETUP=OK
  for db in $DBS; do
    MGR="$(jq -r '.KeyManager // "?"' "$OUT/key-$db.json" 2>/dev/null)"
    ENCRYPTED="$(jq -r '.Encrypted // "?"' "$OUT/db-$db.json" 2>/dev/null)"
    STATUS="$(jq -r '.Status // "?"' "$OUT/db-$db.json" 2>/dev/null)"
    RID="$(cat "$OUT/clumio-id-$db.txt")"
    POLICY="$(jq -r --arg n "$db" '[._embedded.items[]? | select(.name==$n and .is_deleted==false)][0].protection_info.policy_id // "none"' "$OUT/rds-resources.json" 2>/dev/null)"
    BACKUPS="n/a"; [ -n "$RID" ] && BACKUPS="$(jq -r '._embedded.items | length' "$OUT/backups-$db.json" 2>/dev/null || echo '?')"
    echo "$db: key alias=$(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/alias-$db.json" 2>/dev/null) tag exp=$(jq -r '[.[]? | select(.TagKey=="exp") | .TagValue] | if length==0 then "none" else .[0] end' "$OUT/tags-$db.json" 2>/dev/null)"
    echo "$db: status=$STATUS encrypted=$ENCRYPTED key manager=$MGR | Clumio sees it: $([ -n "$RID" ] && echo yes || echo no) | policy: $([ "$POLICY" = "$POLICY_ID" ] && echo ours || echo "$POLICY") | SecureVault backups: $BACKUPS"
    [ "$ENCRYPTED" = "true" ] || SETUP=WRONG
    case "$db" in *-amk) [ "$MGR" = "AWS" ] || SETUP=WRONG ;; *-cmk) [ "$MGR" = "CUSTOMER" ] || SETUP=WRONG ;; esac
  done
  echo "amk database key manager must be AWS, cmk database key manager must be CUSTOMER, both encrypted."
  [ "$SETUP" = OK ] && echo "SETUP: OK" || echo "SETUP: WRONG, the experiment is invalid"
  echo "Clumio snapshots in this account (database | status | key | shared with):"
  jq -r '.[]? | "\(.Snapshot)|\(.Database)|\(.Status) \(.Percent)%|\(.Key | sub("^arn:aws:kms:[a-z0-9-]+:";"") )"' "$OUT/snapshots.json" 2>/dev/null | sed 's/^/  /'
  echo "CloudTrail snapshot calls by Clumio's role, last 24h (create / copy / share / delete): $(for ev in CreateDBSnapshot CopyDBSnapshot ModifyDBSnapshotAttribute DeleteDBSnapshot; do jq -r '[.[]? | fromjson | select(.eventSource=="rds.amazonaws.com") | select((.userIdentity.arn // "") | contains("ClumioIAMRole")) | select((.requestParameters|tostring)|test("amkcmk|clumio-airgap"))] | length' "$OUT/cloudtrail-$ev.json" 2>/dev/null || echo '?'; done | tr '\n' '/' | sed 's#/$##')"
  echo "Shared snapshots (restore attribute values): $(cat "$OUT"/snapshot-shared-*.json 2>/dev/null | jq -s -c '[.[][]? | select(.AttributeName=="restore") | .AttributeValues[]?] | unique')"
  [ -n "$POLICY_ID" ] && echo "Clumio tasks (statuses): $(jq -r '[._embedded.items[]?.status] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' "$OUT/tasks.json" 2>/dev/null || echo '?')"
  echo "Calls that did not succeed:"; grep -vE 'exit=0|http=200' "$LOG" || echo "  none"
} >"$OUT/_summary.txt"

# 4. Fingerprint every file, so later edits are visible.
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )

cat "$OUT/_summary.txt"
echo "Saved: $OUT"
echo "A call listed above as not successful means that file is an error, not evidence."
