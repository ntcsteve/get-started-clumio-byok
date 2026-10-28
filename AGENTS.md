# For AI agents, and anyone changing this repository

This repository is a lab proof: Terraform for a test account, scripts, and saved evidence that Clumio backs up and restores data under AWS-managed and customer-managed KMS keys. Its readers are people who want to check the claims. You help them in one of three ways:

1. **Verify the claims.** Run `scripts/verify-evidence.sh` and read `docs/PROOF.md`. No AWS account is needed.
2. **Repeat the lab** in a test account. `terraform/README.md` is the procedure. The rules below keep it safe.
3. **Change the repository.** See [Changing this repository](#changing-this-repository).

## Map

| Path | What it is |
|---|---|
| `README.md` | The answer, the paths, and Before you begin |
| `docs/PROOF.md` | The claims (C1 to C13), each with a command, the answer, and the raw files |
| `docs/how-it-works.md`, `docs/MAP.md` | The mechanism in words, and who calls what |
| `evidence/` | Saved captures, sanitized, one folder each, with `_sha256.txt`. `evidence/INDEX.md` lists them |
| `terraform/NN-*/` | The lab, one folder per step, each with its own local state. The Clumio modules come from the kit, pinned to a tag |
| `scripts/` | `setup.sh`, the capture scripts (read-only), the restore scripts and `assign-ec2-policy.sh` (they create things), `verify-evidence.sh` |
| `check.sh` | Offline checks of this repository. Ends with `ALL CHECKS PASS` |

## Rules for every task

1. **Plan, then ask, then apply the saved plan.** Run `terraform plan -out=tfplan`, show the person the plan, and wait for their go. Then run `terraform apply tfplan`. Never use `-auto-approve`. One go covers one apply.
2. **The person names the account.** `account_id` in `lab.auto.tfvars` comes from the person, never from a guess. The lab is for a test account only.
3. **Destroying is irreversible.** Follow the teardown order in `terraform/README.md`, and get a go for it. Delete a restored resource only after checking its `exp=amkcmk` tag. SecureVault copies stay until retention ends, and KMS keys wait 7 days.
4. **Never print a secret.** Don't print `CLUMIO_API_TOKEN` or other environment variables. Never open a `*.tfstate` or `tfplan` file, or run `terraform show`: they hold the Clumio ExternalId in plain text. The person exports the token in the shell that starts you.
5. **Never touch resources that are not ours.** Everything this lab creates is named `amkcmk-*` or tagged `exp=amkcmk`. A shared Clumio tenant and a shared AWS account may hold other people's resources and rules.
6. **The person does the console steps:** the Clumio console, the AWS sign-in, and creating the token.

## Changing this repository

**Verify with `./check.sh`.** It ends with `ALL CHECKS PASS`. It never calls AWS or Clumio, so it proves offline behavior only. When it's all that ran, say "tested offline".

**The evidence is a record.** Do not edit files in `evidence/`. If a file must change (a leaked identifier), change it, regenerate that folder's `_sha256.txt`, and say so in `evidence/INDEX.md`.

**Never commit** `lab.auto.tfvars`, state, plans, an account number, a token, or a session token. Examples use `111111111111`. The remote is public: commit only when the person asks, and never push without their go.

**Write the docs like a book:**

- Each fact lives in one place. Elsewhere, link to it.
- Every claim traces to a file in `evidence/`. What isn't proven says so, in `docs/PROOF.md`, under "What this does not prove".
- Full, short sentences. One idea per paragraph. One term per concept. No em dashes.
