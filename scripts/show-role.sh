#!/usr/bin/env bash
# What can Clumio's role do in this account? READ-ONLY. Reads the role's live IAM policies and CloudTrail.
# Made for a screen or a screenshot: it answers "what can it touch, how is it scoped, and will I see it?"
#
#   scripts/show-role.sh              print only
#   SAVE=1 scripts/show-role.sh       also save the output and the raw policies to evidence/role-view-<time>/
#   ROLE=<name> scripts/show-role.sh  a different role (default: the first role named *ClumioIAMRole*)
#
# Account IDs are shortened on screen. The ExternalId value is never printed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# CloudTrail is regional and the profile default is Singapore: pin the lab Region from the one place it is set (lab.auto.tfvars).
export AWS_DEFAULT_REGION="$(awk -F'"' '/^region/ {print $2}' "$HERE/lab.auto.tfvars")"
ME="$(aws sts get-caller-identity --query Account --output text)"
# The account Clumio copies RDS snapshots into. Find it in the role policy or in CloudTrail CopyDBSnapshot events.
VENDOR="${CLUMIO_COPY_ACCOUNT:-222222222222}"
ROLE="${ROLE:-$(aws iam list-roles --query "Roles[?contains(RoleName,'ClumioIAMRole') && starts_with(RoleName,'amkcmk')].RoleName | [0]" --output text)}"
[ -n "$ROLE" ] && [ "$ROLE" != "None" ] || { echo "STOP: no Clumio role found" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
short() { sed -E 's/[0-9]{8}([0-9]{4})/****\1/g'; }

# Gather every policy document of the role into one JSON array of {name, statements}.
aws iam get-role --role-name "$ROLE" --output json >"$TMP/role.json"
for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text); do
  aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" --query PolicyDocument --output json >"$TMP/in-$p.json"
done
for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
  v="$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)"
  aws iam get-policy-version --policy-arn "$arn" --version-id "$v" --query PolicyVersion.Document --output json >"$TMP/at-${arn##*/}.json"
done
# Every Allow statement, flattened: service, action, scope. Scope is ACCOUNT when every resource names
# this account or the vendor snapshot account in the policy, CLUMIO-BUCKET for Clumio's own buckets, else WILDCARD.
jq -s --arg me "$ME" --arg vendor "$VENDOR" '[.[] | .Statement[]? | select(.Effect=="Allow") | ([.Action]|flatten) as $a | ([.Resource]|flatten) as $r
  | ($r | all(.[]; (test(":" + $me + ":")) or test("^arn:aws:s3:::clumio-") or test("accesspoint/clumio") or test(":" + $vendor + ":") )) as $scoped
  | $a[] | {service: (split(":")[0]), action: ., scope: (if $scoped then "ACCOUNT-SCOPED" else "WILDCARD" end)}]' "$TMP"/in-*.json "$TMP"/at-*.json >"$TMP/flat.json"

out() {
echo "ROLE: $ROLE   (account $ME)" | short
echo
echo "== 1. WHO CAN USE THIS ROLE (trust policy)"
jq -r '.Role.AssumeRolePolicyDocument.Statement[] | "  principal : \(.Principal.AWS // .Principal.Service // "?")\n  action    : \(.Action)\n  ExternalId: \(if (.Condition.StringEquals["sts:ExternalId"] // null) then "REQUIRED (value not shown)" else "not required" end)\n  other conditions: \((.Condition // {}) | del(.StringEquals["sts:ExternalId"]) | if . == {} or . == {"StringEquals":{}} then "none" else tostring end)"' "$TMP/role.json" | short
echo
echo "== 2. WHAT IT MAY DO, by service (Allow statements in all of the role's policies)"
printf '  %-14s %8s   %-16s %s\n' SERVICE ACTIONS "ACCOUNT-SCOPED" WILDCARD
jq -r 'group_by(.service) | .[] | [.[0].service, (map(.action)|unique|length), ([.[]|select(.scope=="ACCOUNT-SCOPED")|.action]|unique|length), ([.[]|select(.scope=="WILDCARD")|.action]|unique|length)] | @tsv' "$TMP/flat.json" | sort | awk -F'\t' '{printf "  %-14s %8s   %-16s %s\n",$1,$2,$3,$4}'
echo
echo "== 3. THE ACTIONS A SECURITY REVIEW LOOKS AT FIRST (delete, modify, grant, share), and their scope"
jq -r '[.[] | select(.action|test("Delete|Remove|Revoke|Modify|CreateGrant|PutObjectAcl|PutBucket|PutKeyPolicy|ScheduleKeyDeletion";"i"))] | unique_by(.action + .scope) | sort_by(.service,.action) | .[] | "  \(.scope|if .=="WILDCARD" then "WILDCARD       " else "ACCOUNT-SCOPED " end) \(.action)"' "$TMP/flat.json"
echo
echo "== 4. KEY ACCESS (KMS actions the role holds)"
jq -r '[.[]|select(.service=="kms")|.action]|unique|join(", ")|"  " + .' "$TMP/flat.json"
echo "  (the role's IAM policy, plus the key's own policy, decide use of a key: see the guard test)"
echo
echo "== 5. WILL YOU SEE IT? AssumeRole calls on this role in CloudTrail, last 48h, by session name"
START="$(date -u -v-48H +%Y-%m-%dT%H:%M:%SZ)"
# Searched by the role's ARN as the resource, so a busy account's other AssumeRole calls cannot push ours out.
aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue="$(jq -r '.Role.Arn' "$TMP/role.json")" --start-time "$START" --query 'Events[].CloudTrailEvent' --output json \
  | jq -r --arg role "$ROLE" '[.[]|fromjson|select(.eventName=="AssumeRole")|select((.requestParameters.roleArn // "")|contains($role))] | "  AssumeRole calls: \(length), made by account(s): \([.[].userIdentity.accountId]|unique|join(","))\n  session names: \([.[].requestParameters.roleSessionName]|unique|join(", "))"' | short
echo "  These are the session names Clumio's role used in this window. Filter CloudTrail by a name to see that session's calls."
echo
echo "== 6. WHAT THE TERRAFORM MODULE LETS YOU CONSTRAIN (its input variables)"
MOD="$(ls "$HERE"/terraform/00-connect/.terraform/modules/*/modules/clumio-account-iam/variables.tf 2>/dev/null | head -1)"
[ -n "$MOD" ] && [ -f "$MOD" ] && grep -E '^variable "' "$MOD" | sed -E 's/variable "([a-z_]+)".*/  \1/' | grep -vE '^  connection$' || echo "  (module source not found: run terraform init in terraform/00-connect)"
}

if [ "${SAVE:-}" = 1 ]; then
  D="$HERE/evidence/role-view-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$D"
  cp "$TMP"/role.json "$D/role.json"; for f in "$TMP"/in-*.json "$TMP"/at-*.json; do cp "$f" "$D/$(basename "$f")"; done; cp "$TMP/flat.json" "$D/flattened-allow-statements.json"
  out | tee "$D/_view.txt"
  ( cd "$D" && shasum -a 256 -- * >_sha256.txt ); echo "Saved: $D"
else
  out
fi
