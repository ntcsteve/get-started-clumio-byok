#!/usr/bin/env bash
# Assign (or unassign) the amkcmk-ec2 policy directly to the two test EC2 instances, through the Clumio API.
# WRITES to Clumio: it changes the policy on exactly two instances named amkcmk-ec2-*. Reversible.
#
# Why this script exists (a declared deviation, see terraform/31-ec2-protect/main.tf): our lab tenant was at Clumio's
# limit of 25 policy rules, so a rule cannot be added, and the Terraform provider cannot assign a policy to an
# EC2 instance directly. The API can: POST /policies/assignments, entity type aws_ec2_instance.
#
#   source your Clumio environment file (CLUMIO_API_TOKEN, CLUMIO_API_BASE_URL)
#   scripts/assign-ec2-policy.sh            assign
#   scripts/assign-ec2-policy.sh unassign   undo
set -uo pipefail

ACTION="${1:-assign}"
case "$ACTION" in assign | unassign) ;; *) echo "usage: scripts/assign-ec2-policy.sh [assign|unassign]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars"
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
OUT="$HERE/evidence/ec2-assign-$ACTION-$(date -u +%Y%m%dT%H%M%SZ)"
stop() { echo "STOP: $1" >&2; exit 1; }

[ -n "$ACCOUNT" ] && [ "$REGION" = "ap-southeast-2" ] || stop "lab.auto.tfvars is wrong"
[ -n "${CLUMIO_API_TOKEN:-}" ] && [ -n "${CLUMIO_API_BASE_URL:-}" ] || stop "set CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL first"
NAMES="$(terraform -chdir="$HERE/terraform/30-ec2" output -json instance_names 2>/dev/null | jq -r '.[]?')"
[ "$(echo "$NAMES" | wc -l | tr -d ' ')" = 2 ] || stop "30-ec2 should list exactly 2 instances"
POLICY_ID="$(terraform -chdir="$HERE/terraform/31-ec2-protect" output -raw policy_id 2>/dev/null)"
[ -n "$POLICY_ID" ] || stop "31-ec2-protect has no policy"
mkdir -p "$OUT"

uri() { jq -rn --arg s "$1" '$s|@uri'; }
clumio_get() { printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" | curl -sS -m 30 --config - -H 'Accept: application/json' "$CLUMIO_API_BASE_URL$1"; }

# Each instance's Clumio ID, by name, in this account and Region. A name outside amkcmk-ec2-* is refused.
ITEMS="[]"
for n in $NAMES; do
  case "$n" in amkcmk-ec2-*) ;; *) stop "'$n' is not an amkcmk-ec2-* instance" ;; esac
  ID="$(clumio_get "/datasources/aws/ec2-instances?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
    | jq -r --arg n "$n" --arg r "$REGION" '[._embedded.items[]? | select(.name==$n and .aws_region==$r and .is_deleted==false)][0].id // empty')"
  [ -n "$ID" ] || stop "Clumio does not list $n yet"
  ITEMS="$(echo "$ITEMS" | jq -c --arg id "$ID" --arg a "$ACTION" --arg p "$POLICY_ID" \
    '. + [ {action:$a, entity:{id:$id, type:"aws_ec2_instance"}} + (if $a=="assign" then {policy_id:$p} else {} end) ]')"
done
BODY="$(jq -n --argjson items "$ITEMS" '{items:$items}')"
echo "$BODY" >"$OUT/request.json"

RESPONSE="$(printf 'header = "Authorization: Bearer %s"\n' "$CLUMIO_API_TOKEN" \
  | curl -sS -m 30 --config - -H 'Accept: application/api.clumio.policy-assignments=v1+json' -H 'Content-Type: application/json' \
    -X POST -d "$BODY" -w '\nHTTP %{http_code}\n' "$CLUMIO_API_BASE_URL/policies/assignments")"
echo "$RESPONSE" >"$OUT/response.txt"
TASK="$(echo "$RESPONSE" | sed '$d' | jq -r '.task_id // empty' 2>/dev/null)"
[ -n "$TASK" ] || { cat "$OUT/response.txt" >&2; ( cd "$OUT" && shasum -a 256 -- * >_sha256.txt ); stop "Clumio did not accept the $ACTION. Nothing changed. See $OUT"; }
echo "$ACTION task: $TASK"

STATUS="unknown"; WAITED=0
while [ "$WAITED" -lt 300 ]; do # Bounded: five minutes.
  STATUS="$(clumio_get "/tasks/$TASK" | jq -r '.status // "unknown"')"
  case "$STATUS" in completed | failed | aborted | canceled) break ;; esac
  sleep 10; WAITED=$((WAITED + 10))
done
clumio_get "/tasks/$TASK" >"$OUT/task.json"
# What does Clumio now say each instance's policy is?
clumio_get "/datasources/aws/ec2-instances?limit=200&filter=$(uri "{\"account_native_id\":{\"\$eq\":\"$ACCOUNT\"}}")" \
  | jq '[._embedded.items[]? | select(.name|startswith("amkcmk-ec2")) | {name, aws_region, policy_id: (.protection_info.policy_id // null), is_deleted}]' >"$OUT/instances-after.json"
echo "task $STATUS (waited ${WAITED}s). Policy now on each instance:"
jq -r --arg p "$POLICY_ID" '.[] | "  \(.name): \(if .policy_id == $p then "ours (amkcmk-ec2)" else (.policy_id // "none") end)"' "$OUT/instances-after.json"
( cd "$OUT" && shasum -a 256 -- * >_sha256.txt )
echo "Saved: $OUT"
[ "$STATUS" = completed ]
