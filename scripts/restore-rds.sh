#!/usr/bin/env bash
# Restore each RDS backup into a NEW instance, then check what AWS says about it.
# WRITES: Clumio creates two RDS instances in this account. Run only after a go.
# The restore leaves the key choice to Clumio (no kms_key_native_id), and records which key it picked.
#   E1b (default)   same Region:  instances named <source>-r1.
#   E1c             Singapore:    TARGET_REGION=ap-southeast-1, instances named <source>-sg1. The restore names
#                   key, subnet group and security group that 13-rds-subnets-sg provides: Clumio otherwise
#                   inherits the Sydney values from the backup, and they do not exist in Singapore.
#
#   source your Clumio environment file (CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL)
#   scripts/restore-rds.sh                                    # E1b
#   TARGET_REGION=ap-southeast-1 scripts/restore-rds.sh       # E1c
#   TARGET_KMS_KEY_ID=<key ARN in the target Region> ...  # optional: override the destination key
#
# The restore call is documented at POST /restores/aws/rds-resources; the kit's runner used it live.
# Needs: aws CLI (signed in), terraform, jq, curl, shasum.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars" # The one place the account and Region are set.
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET_REGION="${TARGET_REGION:-$REGION}"
if [ "$TARGET_REGION" = "$REGION" ]; then SUFFIX="-r1"; CROSS=false; KIND="rds-restore"
elif [ "$TARGET_REGION" = "ap-southeast-1" ]; then SUFFIX="-sg1"; CROSS=true; KIND="rds-restore-sg"
else echo "STOP: TARGET_REGION '$TARGET_REGION' is not allowed" >&2; exit 1; fi
# Cross-Region: the request must name the destination key, subnet group and security group. A missing one
# means Clumio inherits a Sydney value that does not exist here, so stop before asking.
TARGET_SUBNET_GROUP=""; TARGET_SECURITY_GROUP_ID=""
if [ "$CROSS" = true ]; then
  NETDIR="$HERE/terraform/13-rds-subnets-sg"
  TARGET_KMS_KEY_ID="${TARGET_KMS_KEY_ID:-$(terraform -chdir="$NETDIR" output -raw kms_key_arn 2>/dev/null)}"
  TARGET_SUBNET_GROUP="$(terraform -chdir="$NETDIR" output -raw subnet_group_name 2>/dev/null)"
  TARGET_SECURITY_GROUP_ID="$(terraform -chdir="$NETDIR" output -raw security_group_id 2>/dev/null)"
  [ -n "$TARGET_KMS_KEY_ID" ] && [ -n "$TARGET_SUBNET_GROUP" ] && [ -n "$TARGET_SECURITY_GROUP_ID" ] \
    || { echo "STOP: a cross-Region restore must name a key, a subnet group and a security group. Apply 13-rds-subnets-sg first." >&2; exit 1; }
fi
OUT="$HERE/evidence/$KIND-$STAMP"
TARGET_KMS_KEY_ID="${TARGET_KMS_KEY_ID:-}"
MAX_WAIT_SECONDS=2400 # Bounded: a restore not finished in 40 minutes is INCONCLUSIVE.

stop() { echo "STOP: $1" >&2; exit 1; }

# Guards: the wrong account, a missing token or a missing apply make the result meaningless.
[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || stop "lab.auto.tfvars is wrong"
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || stop "not signed in to $ACCOUNT"
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || stop "source your Clumio environment file first"
DBS="$(terraform -chdir="$HERE/terraform/20-rds" output -json db_identifiers 2>/dev/null | jq -r '.[]?')"
[ "$(echo "$DBS" | wc -l | tr -d ' ')" = "2" ] || stop "20-rds should list exactly 2 databases"
for db in $DBS; do
  case "$db" in amkcmk-rds-*) ;; *) stop "'$db' is not an amkcmk-rds-* database" ;; esac
  # A restore must never overwrite or collide with anything: its target name must be free.
  aws rds describe-db-instances --region "$TARGET_REGION" --db-instance-identifier "$db$SUFFIX" >/dev/null 2>&1 && stop "$db$SUFFIX already exists in $TARGET_REGION"
done
mkdir -p "$OUT"

uri() { jq -rn --arg s "$1" '$s|@uri'; }
clumio_get() { printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" | curl -sS -m 30 --config - -H 'Accept: application/json' "$CLUMIO_API_BASE_URL$1"; }
clumio_post() {
  printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/api.clumio.restored-aws-rds-resources=v1+json' \
      -H 'Content-Type: application/json' -X POST -d "$2" -w '\nHTTP %{http_code}\n' "$CLUMIO_API_BASE_URL$1"
}

ENV_ID="$(clumio_get "/datasources/aws/environments?filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
  | jq -r --arg a "$ACCOUNT" --arg r "$TARGET_REGION" '[._embedded.items[]? | select(.account_native_id==$a and .aws_region==$r)][0].id // empty')"
[ -n "$ENV_ID" ] || stop "no Clumio connection for $ACCOUNT/$TARGET_REGION"

# 1. Ask Clumio to restore each database's latest backup, with the network settings recorded in that backup.
RESULT=0
declare_tasks=""
for db in $DBS; do
  RID="$(clumio_get "/datasources/aws/rds-resources?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
    | jq -r --arg n "$db" --arg r "$REGION" '[._embedded.items[]? | select(.name==$n and .aws_region==$r and .is_deleted==false)][0].id // empty')"
  [ -n "$RID" ] || stop "Clumio does not list $db"
  clumio_get "/backups/aws/rds-resources?filter=$(uri "{\"resource_id\":{\"\$eq\":\"$RID\"}}")" >"$OUT/backup-record-$db.json"
  BACKUP="$(jq -c '[._embedded.items[]?] | sort_by(.start_timestamp) | last' "$OUT/backup-record-$db.json")"
  BACKUP_ID="$(echo "$BACKUP" | jq -r '.id // empty')"
  [ -n "$BACKUP_ID" ] || stop "no backup of $db to restore"
  BODY="$(echo "$BACKUP" | jq --arg id "$BACKUP_ID" --arg e "$ENV_ID" --arg n "$db$SUFFIX" --argjson cross "$CROSS" --arg kms "$TARGET_KMS_KEY_ID" --arg sn "$TARGET_SUBNET_GROUP" --arg sg "$TARGET_SECURITY_GROUP_ID" \
    '{source:{backup:{backup_id:$id}},
      target:({environment_id:$e, name:$n, instance_class:"db.t4g.micro", is_publicly_accessible:false,
               tags:[{key:"exp",value:"amkcmk"}]}
              + (if $kms != "" then {kms_key_native_id:$kms} else {} end)
              + (if $cross then {subnet_group_name:$sn, security_group_native_ids:[$sg]} else {subnet_group_name:.subnet_group_name, security_group_native_ids:.security_group_native_ids} end))}')"
  echo "$BODY" >"$OUT/request-$db.json"
  RESPONSE="$(clumio_post /restores/aws/rds-resources "$BODY")"
  echo "$RESPONSE" >"$OUT/response-$db.txt"
  TASK="$(echo "$RESPONSE" | sed '$d' | jq -r '.task_id // empty' 2>/dev/null)"
  [ -n "$TASK" ] || { cat "$OUT/response-$db.txt" >&2; ( cd "$OUT" && shasum -a 256 -- * >_sha256.txt ); stop "Clumio did not accept the restore of $db. Check $OUT."; }
  echo "$db -> $db$SUFFIX  restore task $TASK"
  echo "$db $TASK" >>"$OUT/_tasks.txt"
done

# 2. Wait, bounded, until every task has finished. Only these four statuses mean finished.
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT_SECONDS" ]; do
  PENDING=0
  while read -r db task; do
    ST="$(clumio_get "/tasks/$task" | jq -r '.status // "unknown"')"
    case "$ST" in completed | failed | aborted | canceled) ;; *) PENDING=1 ;; esac
  done <"$OUT/_tasks.txt"
  [ "$PENDING" = 0 ] && break
  sleep 30; WAITED=$((WAITED + 30))
done

# 3. What does AWS say about each restored instance? Compare it with its source.
{
  echo "$KIND  UTC $STAMP  account $ACCOUNT  source $REGION -> target $TARGET_REGION  (waited ${WAITED}s)"
  while read -r db task; do
    clumio_get "/tasks/$task" >"$OUT/task-$db.json"
    ST="$(jq -r '.status // "unknown"' "$OUT/task-$db.json")"
    aws rds describe-db-instances --region "$TARGET_REGION" --db-instance-identifier "$db$SUFFIX" \
      --query 'DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine,Version:EngineVersion,Encrypted:StorageEncrypted,KmsKeyId:KmsKeyId,Public:PubliclyAccessible}' >"$OUT/restored-$db.json" 2>"$OUT/restored-$db.err"
    KEY="$(jq -r '.KmsKeyId // empty' "$OUT/restored-$db.json" 2>/dev/null)"
    [ -n "$KEY" ] && aws kms describe-key --region "$TARGET_REGION" --key-id "$KEY" --query 'KeyMetadata.{Arn:Arn,KeyManager:KeyManager}' >"$OUT/restored-key-$db.json" 2>&1
    [ -n "$KEY" ] && aws kms list-aliases --region "$TARGET_REGION" --key-id "$KEY" --query 'Aliases[].AliasName' >"$OUT/restored-alias-$db.json" 2>&1
    SRC_VER="$(jq -r '._embedded.items[0].engine_version' "$OUT/backup-record-$db.json")"
    SRC_KEY="$(jq -r '[._embedded.items[]?] | sort_by(.start_timestamp) | last | .kms_key_native_id' "$OUT/backup-record-$db.json")"
    echo "$db$SUFFIX: task=$ST status=$(jq -r '.Status // "?"' "$OUT/restored-$db.json" 2>/dev/null) encrypted=$(jq -r '.Encrypted // "?"' "$OUT/restored-$db.json" 2>/dev/null) engine=$(jq -r '.Engine' "$OUT/restored-$db.json" 2>/dev/null) $(jq -r '.Version' "$OUT/restored-$db.json" 2>/dev/null) (source $SRC_VER)"
    echo "   restored key: ${KEY##*key/}  manager=$(jq -r '.KeyManager // "?"' "$OUT/restored-key-$db.json" 2>/dev/null)  alias=$(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/restored-alias-$db.json" 2>/dev/null)"
    echo "   source key:   ${SRC_KEY##*key/}"
    { [ "$ST" = "completed" ] && [ "$(jq -r '.Status' "$OUT/restored-$db.json" 2>/dev/null)" = "available" ] && [ "$(jq -r '.Version' "$OUT/restored-$db.json" 2>/dev/null)" = "$SRC_VER" ]; } || RESULT=1
  done <"$OUT/_tasks.txt"
  [ "$RESULT" = 0 ] && echo "$KIND: PASS (task completed, instance available, same engine version). Read the key lines above: in another Region the key may differ. Data is not checked (unseeded databases)." \
    || echo "$KIND: NOT PASSED (a task that did not complete, an instance not available, or a version mismatch; see files)"
} | tee "$OUT/_summary.txt"

# 4. CloudTrail: how Clumio created the instances in our account. Event history keeps 90 days only.
CT_START="$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)"
for ev in CopyDBSnapshot RestoreDBInstanceFromDBSnapshot DeleteDBSnapshot; do
  aws cloudtrail lookup-events --region "$TARGET_REGION" --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" --start-time "$CT_START" \
    --max-results 50 --query 'Events[].CloudTrailEvent' >"$OUT/cloudtrail-$ev.json" 2>&1
done
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
echo "Saved: $OUT"
exit "$RESULT"
