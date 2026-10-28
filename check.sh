#!/usr/bin/env bash
# Checks this repository itself. Run before every commit. Makes no AWS or Clumio calls.
# Needs Terraform 1.5+, python3 and shasum; step 4 also needs the Terraform registry and takes a few minutes.
#   1. shell scripts          every script parses (bash -n)
#   2. evidence checksums     every evidence folder matches its _sha256.txt
#   3. terraform fmt          every .tf file is formatted
#   4. terraform validate     every folder, on a copy, with its committed lock file
#   5. references             every relative link and every evidence/ folder named in the docs exists; every terraform folder is in terraform/README.md
#   6. publish hygiene        no state, plan or credentials; no unreadable evidence file; no account number except the placeholders
set -euo pipefail

cd "$(dirname "$0")"
FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
flunk() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
COPIES="$(mktemp -d)"
trap 'rm -rf "$COPIES"' EXIT

# 1
BAD=""; for f in scripts/*.sh check.sh; do bash -n "$f" 2>/dev/null || BAD="$BAD $f"; done
[ -z "$BAD" ] && pass "1 shell scripts parse" || flunk "1 shell scripts do not parse:$BAD"

# 2
scripts/verify-evidence.sh >"$COPIES/verify.txt" 2>&1 && pass "2 evidence checksums ($(grep -m1 folders "$COPIES/verify.txt"))" || { flunk "2 evidence checksums"; cat "$COPIES/verify.txt"; }

# 3
terraform fmt -check -recursive terraform >/dev/null 2>&1 && pass "3 terraform fmt" || flunk "3 terraform fmt (run: terraform fmt -recursive terraform)"

# 4 (on copies: never touches your .terraform, state or lab.auto.tfvars)
VALID=0; TOTAL=0
for dir in terraform/[0-9][0-9]-*/; do
  name="$(basename "$dir")"; TOTAL=$((TOTAL + 1)); mkdir -p "$COPIES/tf/$name"
  cp "$dir"/*.tf "$dir"/.terraform.lock.hcl "$COPIES/tf/$name/"
  if (cd "$COPIES/tf/$name" && terraform init -backend=false -input=false -lockfile=readonly >init.log 2>&1 && terraform validate >val.log 2>&1); then
    VALID=$((VALID + 1))
  else
    flunk "4 terraform validate $name (see below)"; tail -5 "$COPIES/tf/$name/init.log" "$COPIES/tf/$name/val.log" 2>/dev/null
  fi
done
[ "$VALID" = "$TOTAL" ] && pass "4 terraform validate ($VALID of $TOTAL folders)"

# 5 and 6
python3 - "$PWD" <<'PY' && pass "5 references and 6 publish hygiene" || flunk "5 or 6 (see the lines above)"
import re, sys
from pathlib import Path
root = Path(sys.argv[1]); bad = []
docs = [root / "README.md", root / "SECURITY.md", root / "AGENTS.md", root / "terraform/README.md", root / "evidence/INDEX.md", *sorted((root / "docs").glob("*.md"))]
for doc in docs:
    text = doc.read_text()
    for target in re.findall(r"\]\((?!https?://|#|mailto:)([^)#\s]+)", text):
        if not (doc.parent / target).resolve().exists():
            bad.append(f"{doc.relative_to(root)}: broken link {target}")
    for folder in set(re.findall(r"evidence/([a-z0-9-]+-\d{8}T\d{6}Z)", text)):
        if not (root / "evidence" / folder).is_dir():
            bad.append(f"{doc.relative_to(root)}: evidence folder {folder} does not exist")
readme = (root / "terraform/README.md").read_text()
for folder in sorted(p.name for p in (root / "terraform").iterdir() if p.is_dir()):
    short = folder.split("-", 1)[0]
    if f"`{folder}`" not in readme and short not in readme:
        bad.append(f"terraform/README.md does not mention {folder}")
allowed_numbers = {"111111111111", "222222222222", "333333333333", "137112412989"}  # placeholders, and Amazon's public AMI owner id
for f in sorted(root.rglob("*")):
    rel = f.relative_to(root)
    if not f.is_file() or ".git" in rel.parts or "node_modules" in rel.parts or f.suffix == ".png":
        continue
    if re.search(r"(\.tfstate|tfplan|\.env$|\.pem$|/\.terraform/)", f"/{rel}") or rel.name == "lab.auto.tfvars":
        bad.append(f"{rel}: state, plan or credential file")
        continue
    raw = f.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        bad.append(f"{rel}: not valid UTF-8"); continue
    if raw[:2] == b"\x1f\x8b":
        bad.append(f"{rel}: gzip file")
    if re.search(r'"(?:sessionToken|secretAccessKey)"\s*:\s*"(?!REDACTED")', text):
        bad.append(f"{rel}: unredacted session token or secret key")
    if re.search(r"\b(?:ASIA|AKIA)(?!X{16}\b)[A-Z0-9]{16}\b", text):
        bad.append(f"{rel}: access key id")
    if rel.as_posix() != "check.sh":
        for number in set(re.findall(r"(?<![0-9A-Za-z-])\d{12}(?![0-9A-Za-z-])", text)) - allowed_numbers:
            bad.append(f"{rel}: 12-digit number {number[:2]}**********")
for line in bad[:40]:
    print("      ", line)
sys.exit(1 if bad else 0)
PY

echo
[ "$FAILED" = 0 ] && echo "ALL CHECKS PASS" || { echo "CHECKS FAILED"; exit 1; }
