#!/usr/bin/env bash
# READ-ONLY. Shows, from the saved EC2 backup evidence, which snapshots Clumio's role made in our account and under which key.
#   scripts/show-ec2-snapshots.sh
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)/evidence/ec2-20261026T090741Z"
short() { sed -E 's/[0-9]{8}([0-9]{4})/****\1/g'; } # 111111111111 -> ****1111
echo "== EC2 BACKUP: WHAT CLUMIO'S ROLE MADE IN OUR ACCOUNT (saved evidence, $(basename "$D"))"
echo "SNAPSHOT               KEY       TAGS"
jq -r '.[] | "\(.Id)  \(.Key | split("/")[-1][0:8])  \((.Tags // []) | map(select(.Key=="Name" or .Key=="Vendor")) | sort_by(.Key) | map("\(.Key)=\(.Value)") | join(" "))"' "$D/snapshots.json"
echo
echo "CloudTrail CreateSnapshots, by the session of Clumio's role:"
jq -r '.[] | fromjson | "\(.eventTime[0:19])  \(.eventName)  \(.userIdentity.arn | split("/") | .[-2:] | join("/"))"' "$D/cloudtrail-CreateSnapshots.json" | sort | short
