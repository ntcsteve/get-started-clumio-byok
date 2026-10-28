#!/usr/bin/env bash
# One-time setup. Creates lab.auto.tfvars (git-ignored) from the example, then links it into every terraform/NN-* folder,
# so the account and Region are set in ONE place. The capture scripts read the same file.
# Run it from anywhere; run it again after you edit lab.auto.tfvars. It changes nothing outside this repository.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/lab.auto.tfvars"

if [ ! -f "$LAB" ]; then
  cp "$HERE/lab.auto.tfvars.example" "$LAB"
  echo "Created $LAB. Set account_id to your TEST account, then run scripts/setup.sh again."
  exit 0
fi
ACCOUNT="$(awk -F'"' '/^account_id/ {print $2}' "$LAB")"
REGION="$(awk -F'"' '/^region/ {print $2}' "$LAB")"
case "$ACCOUNT" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "STOP: account_id in lab.auto.tfvars must be a 12-digit account number." >&2; exit 1 ;;
esac
[ "$ACCOUNT" != "111111111111" ] || { echo "STOP: account_id is still the example value. Set your test account." >&2; exit 1; }
[ "$REGION" = "ap-southeast-2" ] || { echo "STOP: region must be ap-southeast-2 (the lab is pinned to it)." >&2; exit 1; }

for dir in "$HERE"/terraform/[0-9][0-9]-*/; do
  ln -sfn ../../lab.auto.tfvars "$dir/lab.auto.tfvars"
done
echo "OK: account ****${ACCOUNT: -4}, region $REGION, linked into $(ls -d "$HERE"/terraform/[0-9][0-9]-*/ | wc -l | tr -d ' ') folders."
