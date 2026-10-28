#!/usr/bin/env bash
# Experiment E4b: restore each EC2 backup into a NEW instance, then check what AWS says about it.
# WRITES: Clumio creates two EC2 instances (named <source>-r1) in this account. Run only after a go.
# By default the request names no KMS key, so Clumio's default is observed and recorded (E4b: the restored
# volumes came back UNENCRYPTED). With RESTORE_KEYS=1 the request names each source volume's own key (E4c).
#
#   source your Clumio environment file (CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL)
#   scripts/restore-ec2.sh                  names no key (instances are named <source>-r1)
#   RESTORE_KEYS=1 scripts/restore-ec2.sh   names each backup's source key (instances are named <source>-r2)
#
# Needs: aws CLI (signed in), terraform, jq, curl, shasum.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars"
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$HERE/evidence/ec2-restore-$STAMP"
if [ "${RESTORE_KEYS:-}" = 1 ]; then SUFFIX="-r2"; NAME_KEYS=true; else SUFFIX="-r1"; NAME_KEYS=false; fi
MAX_WAIT_SECONDS=2400 # Bounded: 40 minutes, then INCONCLUSIVE.
stop() { echo "STOP: $1" >&2; exit 1; }

[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || stop "lab.auto.tfvars is wrong"
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || stop "not signed in to $ACCOUNT"
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || stop "set CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL first"
NAMES="$(terraform -chdir="$HERE/terraform/30-ec2" output -json instance_names 2>/dev/null | jq -r '.[]?')"
[ "$(echo "$NAMES" | wc -l | tr -d ' ')" = 2 ] || stop "30-ec2 should list exactly 2 instances"
for n in $NAMES; do
  case "$n" in amkcmk-ec2-*) ;; *) stop "'$n' is not an amkcmk-ec2-* instance" ;; esac
  # A restore must never collide with anything: its target name must be free.
  [ "$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$n$SUFFIX" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'length(Reservations)' --output text)" = 0 ] || stop "$n$SUFFIX already exists"
done
mkdir -p "$OUT"

uri() { jq -rn --arg s "$1" '$s|@uri'; }
clumio_get() { printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" | curl -sS -m 30 --config - -H 'Accept: application/json' "$CLUMIO_API_BASE_URL$1"; }
clumio_post() {
  printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
    | curl -sS -m 30 --config - -H 'Accept: application/api.clumio.restored-aws-ec2-instances=v1+json' \
      -H 'Content-Type: application/json' -X POST -d "$2" -w '\nHTTP %{http_code}\n' "$CLUMIO_API_BASE_URL$1"
}
ENV_ID="$(clumio_get "/datasources/aws/environments?filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
  | jq -r --arg a "$ACCOUNT" --arg r "$REGION" '[._embedded.items[]? | select(.account_native_id==$a and .aws_region==$r)][0].id // empty')"
[ -n "$ENV_ID" ] || stop "no Clumio connection for $ACCOUNT/$REGION"

# 1. Ask Clumio to restore each instance's latest backup, with the configuration recorded in that backup.
for n in $NAMES; do
  RID="$(clumio_get "/datasources/aws/ec2-instances?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
    | jq -r --arg n "$n" --arg r "$REGION" '[._embedded.items[]? | select(.name==$n and .aws_region==$r and .is_deleted==false)][0].id // empty')"
  [ -n "$RID" ] || stop "Clumio does not list $n"
  clumio_get "/backups/aws/ec2-instances?filter=$(uri "{\"instance_id\":{\"\$eq\":\"$RID\"}}")" >"$OUT/backup-record-$n.json"
  BACKUP="$(jq -c '[._embedded.items[]?] | sort_by(.start_timestamp) | last' "$OUT/backup-record-$n.json")"
  BACKUP_ID="$(echo "$BACKUP" | jq -r '.id // empty')"
  [ -n "$BACKUP_ID" ] || stop "no backup of $n to restore"
  BODY="$(echo "$BACKUP" | jq --arg id "$BACKUP_ID" --arg e "$ENV_ID" --arg n "$n$SUFFIX" --argjson keys "$NAME_KEYS" \
    '{source:{backup_id:$id},
      target:{instance_restore_target:{
        environment_id:$e, aws_az:.aws_az, subnet_native_id:.subnet_native_id, vpc_native_id:.vpc_native_id,
        should_power_on:true,
        ebs_block_device_mappings:[.attached_backup_ebs_volumes[] | {name:.name, volume_native_id:.volume_native_id} + (if $keys then {kms_key_native_id:.kms_key_native_id} else {} end)],
        network_interfaces:[.network_interfaces[] | {device_index:.device_index, restore_default:true, subnet_native_id:.subnet_native_id, security_group_native_ids:.security_group_native_ids}],
        tags:[{key:"exp",value:"amkcmk"},{key:"Name",value:$n}]}}}')"
  echo "$BODY" >"$OUT/request-$n.json"
  RESPONSE="$(clumio_post /restores/aws/ec2-instances "$BODY")"
  echo "$RESPONSE" >"$OUT/response-$n.txt"
  TASK="$(echo "$RESPONSE" | sed '$d' | jq -r '.task_id // empty' 2>/dev/null)"
  [ -n "$TASK" ] || { cat "$OUT/response-$n.txt" >&2; ( cd "$OUT" && shasum -a 256 -- * >_sha256.txt ); stop "Clumio did not accept the restore of $n. Check $OUT."; }
  echo "$n -> $n$SUFFIX  restore task $TASK"; echo "$n $TASK" >>"$OUT/_tasks.txt"
done

# 2. Wait, bounded, until every task has finished.
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT_SECONDS" ]; do
  PENDING=0
  while read -r n task; do
    ST="$(clumio_get "/tasks/$task" | jq -r '.status // "unknown"')"
    case "$ST" in completed | failed | aborted | canceled) ;; *) PENDING=1 ;; esac
  done <"$OUT/_tasks.txt"
  [ "$PENDING" = 0 ] && break
  sleep 30; WAITED=$((WAITED + 30))
done

# 3. What does AWS say about each restored instance, its root volume and that volume's key?
RESULT=0
{
  echo "ec2-restore  UTC $STAMP  account $ACCOUNT  region $REGION  (waited ${WAITED}s)"
  while read -r n task; do
    clumio_get "/tasks/$task" >"$OUT/task-$n.json"; ST="$(jq -r '.status // "unknown"' "$OUT/task-$n.json")"
    aws ec2 describe-instances --filters "Name=tag:Name,Values=$n$SUFFIX" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Type:InstanceType,Root:BlockDeviceMappings[0].Ebs.VolumeId}' >"$OUT/restored-$n.json" 2>&1
    VOL="$(jq -r '.Root // empty' "$OUT/restored-$n.json" 2>/dev/null)"
    [ -n "$VOL" ] && aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].{Id:VolumeId,Encrypted:Encrypted,KmsKeyId:KmsKeyId,Size:Size,State:State}' >"$OUT/restored-volume-$n.json" 2>&1
    KEY="$(jq -r '.KmsKeyId // empty' "$OUT/restored-volume-$n.json" 2>/dev/null)"
    [ -n "$KEY" ] && aws kms describe-key --key-id "$KEY" --query 'KeyMetadata.{Arn:Arn,KeyManager:KeyManager}' >"$OUT/restored-key-$n.json" 2>&1
    [ -n "$KEY" ] && aws kms list-aliases --key-id "$KEY" --query 'Aliases[].AliasName' >"$OUT/restored-alias-$n.json" 2>&1
    SRC_KEY="$(jq -r '[._embedded.items[]?] | sort_by(.start_timestamp) | last | .attached_backup_ebs_volumes[0].kms_key_native_id' "$OUT/backup-record-$n.json")"
    ENC="$(jq -r '.Encrypted | tostring' "$OUT/restored-volume-$n.json" 2>/dev/null)" # tostring: jq's // treats false as missing
    echo "$n$SUFFIX: task=$ST instance=$(jq -r '.State // "?"' "$OUT/restored-$n.json" 2>/dev/null) root volume ENCRYPTED=$ENC (key named in the request: $NAME_KEYS)"
    echo "   restored key: ${KEY##*key/}  manager=$(jq -r '.KeyManager // "?"' "$OUT/restored-key-$n.json" 2>/dev/null)  alias=$(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/restored-alias-$n.json" 2>/dev/null)"
    echo "   source key:   ${SRC_KEY##*/}"
    { [ "$ST" = completed ] && [ "$(jq -r '.State' "$OUT/restored-$n.json" 2>/dev/null)" = running ]; } || RESULT=1
  done <"$OUT/_tasks.txt"
  [ "$RESULT" = 0 ] && echo "ec2-restore: PASS (task completed, instance running). Read the ENCRYPTED and key lines: encryption is a separate question." \
    || echo "ec2-restore: NOT PASSED (a task that did not complete, or an instance not running; see files)"
} | tee "$OUT/_summary.txt"

# 4. CloudTrail: how Clumio created the instances in our account.
for ev in RunInstances CreateVolume CreateSnapshot DeleteSnapshot StartSnapshot; do
  aws cloudtrail lookup-events --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" --start-time "$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)" \
    --max-results 50 --query 'Events[].CloudTrailEvent' >"$OUT/cloudtrail-$ev.json" 2>&1
done
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
echo "Saved: $OUT"
exit "$RESULT"
