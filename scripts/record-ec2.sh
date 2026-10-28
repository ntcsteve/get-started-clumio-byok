#!/usr/bin/env bash
# Evidence capture for experiment E4 (EC2 with an AWS-managed EBS key). READ-ONLY: it changes nothing.
# Saves raw output, then a short summary, so the conclusion can be re-checked by someone who was not here.
#
#   source your Clumio environment file (CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL)
#   scripts/record-ec2.sh           writes evidence/ec2-<UTC time>/
#
# Needs: aws CLI (signed in), terraform, jq, curl, shasum.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars"
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
export AWS_DEFAULT_REGION="$REGION"
OUT="$HERE/evidence/ec2-$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT/_calls.log"

[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || { echo "STOP: lab.auto.tfvars is wrong" >&2; exit 1; }
[ "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" = "$ACCOUNT" ] || { echo "STOP: not signed in to $ACCOUNT" >&2; exit 1; }
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || { echo "STOP: set CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL first" >&2; exit 1; }
NAMES="$(terraform -chdir="$HERE/terraform/30-ec2" output -json instance_names 2>/dev/null | jq -r '.[]?')"
[ -n "$NAMES" ] || { echo "STOP: 30-ec2 has no instances. Has it been applied?" >&2; exit 1; }
POLICY_ID="$(terraform -chdir="$HERE/terraform/31-ec2-protect" output -raw policy_id 2>/dev/null)"
[ -n "$POLICY_ID" ] || echo "NOTE: 31-ec2-protect not applied yet; Clumio protection will not be captured." >&2
mkdir -p "$OUT"

aws_save() { local f="$1"; shift; "$@" >"$OUT/$f" 2>&1; echo "aws    exit=$?  $f" >>"$LOG"; }
clumio_save() { local f="$1" p="$2" c
  c="$(printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" | curl -sS -m 30 --config - -H 'Accept: application/json' -o "$OUT/$f" -w '%{http_code}' "$CLUMIO_API_BASE_URL$p")"
  echo "clumio http=$c  $f" >>"$LOG"; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }

date -u +%Y-%m-%dT%H:%M:%SZ >"$OUT/utc-time.txt"

# 1. The instance, its root volume, and the key that volume really uses (AWS-managed or customer-managed).
for n in $NAMES; do
  aws_save "instance-$n.json" aws ec2 describe-instances --filters "Name=tag:Name,Values=$n" "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Type:InstanceType,Root:BlockDeviceMappings[0].Ebs.VolumeId}'
  VOL="$(jq -r '.Root // empty' "$OUT/instance-$n.json" 2>/dev/null)"
  [ -n "$VOL" ] && aws_save "volume-$n.json" aws ec2 describe-volumes --volume-ids "$VOL" \
    --query 'Volumes[0].{Id:VolumeId,Encrypted:Encrypted,KmsKeyId:KmsKeyId,Size:Size,State:State}'
  KEY="$(jq -r '.KmsKeyId // empty' "$OUT/volume-$n.json" 2>/dev/null)"
  if [ -n "$KEY" ]; then
    aws_save "key-$n.json" aws kms describe-key --key-id "$KEY" --query 'KeyMetadata.{Arn:Arn,KeyManager:KeyManager,KeyState:KeyState}'
    aws_save "key-full-$n.json" aws kms describe-key --key-id "$KEY"
    aws_save "alias-$n.json" aws kms list-aliases --key-id "$KEY" --query 'Aliases[].AliasName'
    aws_save "tags-$n.json" aws kms list-resource-tags --key-id "$KEY" --query 'Tags'
  fi
done
# The AWS-managed EBS key's own policy, by key id (an alias is refused).
for n in $NAMES; do
  [ "$(jq -r '.KeyManager // empty' "$OUT/key-$n.json" 2>/dev/null)" = "AWS" ] && \
    aws_save "policy-aws-managed-key.json" aws kms get-key-policy --key-id "$(jq -r '.Arn' "$OUT/key-$n.json" | sed 's#.*key/##')" --policy-name default --query Policy --output text
done

# 2. Snapshots in the account, with their key and tags. Clumio's role makes and later removes its own.
aws_save snapshots.json aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[].{Id:SnapshotId,Volume:VolumeId,Encrypted:Encrypted,Key:KmsKeyId,State:State,Start:StartTime,Tags:Tags}'
# 3. CloudTrail: what Clumio's role did to snapshots in this account (last 24h).
for ev in CreateSnapshot CreateSnapshots CopySnapshot DeleteSnapshot ModifySnapshotAttribute; do
  aws_save "cloudtrail-$ev.json" aws cloudtrail lookup-events --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" \
    --start-time "$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)" --max-results 50 --query 'Events[].CloudTrailEvent'
done

# 4. Clumio: does it see the instances, which policy do they have, and what backups exist?
clumio_save ec2-instances.json "/datasources/aws/ec2-instances?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")"
for n in $NAMES; do
  RID="$(jq -r --arg n "$n" --arg r "$REGION" '[._embedded.items[]? | select(.name==$n and .aws_region==$r and .is_deleted==false)][0].id // empty' "$OUT/ec2-instances.json" 2>/dev/null)"
  echo "$RID" >"$OUT/clumio-id-$n.txt"
  # This endpoint filters on instance_id (resource_id is refused with HTTP 400).
  [ -n "$RID" ] && clumio_save "backups-$n.json" "/backups/aws/ec2-instances?filter=$(uri "{\"instance_id\":{\"\$eq\":\"$RID\"}}")"
done
# EC2 backup tasks are named by instance ID, not by instance name, so look them up by ID.
if [ -n "$POLICY_ID" ]; then
  for id in $(terraform -chdir="$HERE/terraform/30-ec2" output -json instance_ids 2>/dev/null | jq -r '.[]?'); do
    clumio_save "tasks-$id.json" "/tasks?limit=20&filter=$(uri "{\"primary_entity.value\":{\"\$contains\":\"$id\"}}")"
  done
fi

{
  echo "UTC $(cat "$OUT/utc-time.txt")  account $ACCOUNT  region $REGION"
  SETUP=OK
  for n in $NAMES; do
    MGR="$(jq -r '.KeyManager // "?"' "$OUT/key-$n.json" 2>/dev/null)"; ENC="$(jq -r '.Encrypted | tostring' "$OUT/volume-$n.json" 2>/dev/null)"
    RID="$(cat "$OUT/clumio-id-$n.txt")"; BK="n/a"; [ -n "$RID" ] && BK="$(jq -r '._embedded.items | length' "$OUT/backups-$n.json" 2>/dev/null || echo '?')"
    echo "$n: $(jq -r '.State // "?"' "$OUT/instance-$n.json" 2>/dev/null), root volume encrypted=$ENC, key manager=$MGR, alias=$(jq -r 'join(",") | if .=="" then "none" else . end' "$OUT/alias-$n.json" 2>/dev/null) | Clumio sees it: $([ -n "$RID" ] && echo yes || echo no) | backups: $BK"
    [ "$ENC" = "true" ] || SETUP=WRONG
    case "$n" in *-amk) [ "$MGR" = "AWS" ] || SETUP=WRONG ;; *-cmk) [ "$MGR" = "CUSTOMER" ] || SETUP=WRONG ;; esac
  done
  [ "$SETUP" = OK ] && echo "SETUP: OK" || echo "SETUP: WRONG, the experiment is invalid"
  for f in "$OUT"/tasks-i-*.json; do [ -f "$f" ] && jq -r '._embedded.items[]? | "Clumio task \(.id) \(.type) \(.status) \(.progress_percentage)% (instance \(.primary_entity.value))"' "$f"; done
  echo "Clumio snapshots in the account: $(jq -r '[.[]? | select(.Tags // [] | map(.Key) | index("Vendor"))] | length' "$OUT/snapshots.json" 2>/dev/null) (tagged Vendor=Clumio)"
  echo "Calls that did not succeed:"; grep -vE 'exit=0|http=200' "$LOG" || echo "  none"
} >"$OUT/_summary.txt"
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
cat "$OUT/_summary.txt"; echo "Saved: $OUT"
