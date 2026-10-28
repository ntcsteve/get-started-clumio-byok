#!/usr/bin/env bash
# A clean, READ-ONLY on-screen demo of the AMK / CMK proof, made for a screenshot or a screen recording.
# It changes nothing. It asks AWS (not our files) and prints a compact table plus the CloudTrail sequence.
#
#   scripts/demo-proof.sh            (AWS signed in; no Clumio token needed)
#
# Account IDs are shortened to the last 4 digits on screen. Nothing secret is printed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REGION="$(awk -F'"' '/^region/ {print $2}' "$HERE/lab.auto.tfvars")"
export AWS_DEFAULT_REGION="$REGION"
# BUCKET and DBS can be set in the environment to run this without our Terraform state.
BUCKET="${BUCKET:-$(terraform -chdir="$HERE/terraform/10-s3" output -raw bucket_name 2>/dev/null)}"
DBS="${DBS:-$(terraform -chdir="$HERE/terraform/20-rds" output -json db_identifiers 2>/dev/null | jq -r '.[]?')}"
[ -n "$BUCKET" ] && [ -n "$DBS" ] || { echo "STOP: 10-s3 and 20-rds must be applied" >&2; exit 1; }
short() { sed -E 's/[0-9]{8}([0-9]{4})/****\1/g'; } # 111111111111 -> ****1111

line() { printf '%-22s %-10s %-10s %s\n' "$1" "$2" "$3" "$4"; }
describe() { # <label> <key arn>
  local id="${2##*/}" alias
  alias="$(aws kms list-aliases --key-id "$2" --query 'Aliases[].AliasName' --output text)"
  line "$1" "${id:0:8}" "$(aws kms describe-key --key-id "$2" --query KeyMetadata.KeyManager --output text)" "${alias:-(none, our own key)}"
}

echo "== 1. WHICH KEY? Read from AWS, not from our files"
line "RESOURCE" "KEY" "MANAGER" "ALIAS"
for obj in amk cmk; do
  describe "S3 $obj.txt" "$(aws s3api head-object --bucket "$BUCKET" --key "$obj.txt" --query SSEKMSKeyId --output text)"
done
for db in $DBS; do
  describe "RDS $db" "$(aws rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].KmsKeyId' --output text)"
done

echo
echo "== 2. WHAT DID CLUMIO DO TO THE AWS-MANAGED RDS DATABASE? CloudTrail"
HOURS="${PROOF_HOURS:-48}" # CloudTrail Event history keeps 90 days; widen with PROOF_HOURS=n
START="$(date -u -v-"$HOURS"H +%Y-%m-%dT%H:%M:%SZ)"
echo "(searching CloudTrail from $START, the last $HOURS hours)"
for ev in CreateDBSnapshot CopyDBSnapshot ModifyDBSnapshotAttribute DeleteDBSnapshot; do
  aws cloudtrail lookup-events --lookup-attributes "AttributeKey=EventName,AttributeValue=$ev" --start-time "$START" \
    --max-results 50 --query 'Events[].CloudTrailEvent' --output json \
    | jq -r --arg ev "$ev" '.[] | fromjson | select(.eventSource=="rds.amazonaws.com")
        | select((.userIdentity.arn // "") | contains("ClumioIAMRole"))
        | select((.requestParameters|tostring) | contains("t4043795459"))
        | "\(.eventTime[11:19]) \($ev)  \(.requestParameters | (.kmsKeyId // "" | sub("^arn:aws:kms:[a-z0-9-]+:";"") | sub(":key/";" / ")) + (if .valuesToAdd then "share with " + (.valuesToAdd|join(",")) else "" end) + (if (.sourceDBSnapshotIdentifier // "") | contains("final") then "   [restore, later]" else "" end))"'
done | sort | short

echo
echo "== 3. WAS THE AWS-MANAGED SNAPSHOT EVER SHARED?"
SHARES="$(aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=ModifyDBSnapshotAttribute --start-time "$START" --max-results 50 \
  --query 'Events[].CloudTrailEvent' --output json | jq '[.[]|fromjson|select((.requestParameters|tostring)|contains("to-encrypt"))]|length')"
CREATED="$(aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateDBSnapshot --start-time "$START" --max-results 50 \
  --query 'Events[].CloudTrailEvent' --output json | jq '[.[]|fromjson|select((.userIdentity.arn // "")|contains("ClumioIAMRole"))|select((.requestParameters.dBSnapshotIdentifier // "")|contains("to-encrypt"))]|length')"
if [ "$CREATED" = 0 ]; then
  echo "NOTHING TO CHECK: this window holds no Clumio snapshot creation, so a 0 here would mean nothing."
  echo "Widen it: PROOF_HOURS=72 scripts/demo-proof.sh  (Event history keeps 90 days)"
else
  echo "Clumio created $CREATED AWS-managed-key snapshot(s) in this window; shares of such a snapshot: $SHARES"
fi

echo
echo "== 4. DID CLUMIO'S ROLE USE THE AWS-MANAGED S3 KEY? KMS Decrypt events"
# No --max-results here (the other blocks keep 50). Decrypt is the busiest KMS event: EBS backups add hundreds, and a cap
# of the newest 50 pushed the S3 ones out of view. The CLI pages through them all, which takes about 30 seconds.
# (A lookup by key or by session name did not return these events, so the event name is the filter.)
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=Decrypt --start-time "$START" \
  --query 'Events[].CloudTrailEvent' --output json \
  | jq -r '.[] | fromjson | select((.userIdentity.arn // "") | contains("ClumioIAMRole"))
      | select((.requestParameters.encryptionContext["aws:s3:arn"] // "") | contains("amkcmk-s3"))
      | "\(.eventTime[5:10]) \(.eventTime[11:19]) Decrypt  key \((.resources[0].ARN // "?") | sub(".*key/";"") | .[0:8])  object \(.requestParameters.encryptionContext["aws:s3:arn"] | sub(".*/";""))  via \(.userIdentity.invokedBy // "-")"' | sort

echo
echo "== 5. CALLS IN OUR ACCOUNT MADE BY ANOTHER ACCOUNT (not by Clumio's role), CopyDBSnapshot"
ME="$(aws sts get-caller-identity --query Account --output text)"
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CopyDBSnapshot --start-time "$START" --max-results 50 \
  --query 'Events[].CloudTrailEvent' --output json \
  | jq -r --arg me "$ME" '.[] | fromjson | select(.userIdentity.accountId != $me)
      | "\(.eventTime[11:19]) \(.eventName) by account \(.userIdentity.accountId)  user agent: \(.userAgent | .[0:34])"' | sort | short

echo
echo "Reading guide: the snapshot calls in section 2 and the decrypts in section 4 were made by Clumio's role"
echo "sessions; section 5 lists the calls made by another account. That account is inferred, not confirmed, to be Commvault's."
