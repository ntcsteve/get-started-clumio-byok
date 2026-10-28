#!/usr/bin/env bash
# Verifies every evidence folder against its sha256 manifest. READ-ONLY, offline, needs no credentials.
# It catches a file that was changed after capture. It cannot catch an added file or a regenerated
# manifest: for that, keep the printed root hash somewhere outside this folder.
#
#   scripts/verify-evidence.sh
#
# It checks each folder from INSIDE the folder, because the manifests use relative paths. Running
# shasum from anywhere else reports false failures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FOLDERS=0; FILES=0; FAILED=0
for dir in "$HERE"/evidence/*/; do
  [ -f "$dir/_sha256.txt" ] || continue
  FOLDERS=$((FOLDERS + 1))
  RESULT="$(cd "$dir" && shasum -a 256 -c _sha256.txt 2>&1)"
  OK="$(echo "$RESULT" | grep -c ': OK$')"
  BAD="$(echo "$RESULT" | grep -vc ': OK$')"
  FILES=$((FILES + OK)); FAILED=$((FAILED + BAD))
  [ "$BAD" = 0 ] || { echo "FAILED  $(basename "$dir"): $BAD file(s)"; echo "$RESULT" | grep -v ': OK$' | sed 's/^/          /'; }
done
echo "$FOLDERS folders, $FILES files verified, $FAILED failures"
# A checksum file can be regenerated after a file is edited, and an added file is not listed at all.
# This one hash covers every manifest: store it somewhere we do not control (an email, a third party)
# and anyone can later see whether the manifests changed.
echo "root hash of all manifests: $(cat "$HERE"/evidence/*/_sha256.txt | shasum -a 256 | cut -d' ' -f1)"
[ "$FAILED" = 0 ] && echo "RESULT: OK" || echo "RESULT: EVIDENCE CHANGED OR MISSING"
exit "$FAILED"
