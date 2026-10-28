# Terraform: the lab, step by step

One folder per step. Each folder is its own Terraform root with its own local state. Review every plan before you apply. Nothing here uses `-auto-approve`.

## Set up once

From the repository root, run `scripts/setup.sh`. It creates `lab.auto.tfvars` (git-ignored) from the example. Set `account_id` to your test account, then run it again: it links that one file into every `terraform/NN-*` folder, so the account and Region are set in one place. The capture scripts read the same file.

Sign in to AWS for the test account. For the Clumio side, set `CLUMIO_API_TOKEN` and `CLUMIO_API_BASE_URL` as in the kit's [Before you begin](https://github.com/ntcsteve/get-started-clumio-aws#before-you-begin). Then, in each folder: `terraform init`, `terraform plan -out=tfplan`, read it, `terraform apply tfplan`. Do not open `*.tfstate` or `tfplan`: they hold the Clumio ExternalId and token.

The scripts target macOS. On Linux, replace `date -u -v-24H` with `date -u -d '24 hours ago'`.

## Apply order

| Folder | Creates | Needs |
|---|---|---|
| `00-connect` | Connects the account and Region to Clumio, with its IAM roles (prefix `amkcmk`) | none |
| `10-s3` | Bucket with `amk.txt` (`aws/s3`) and `cmk.txt` (your key) | none |
| `11-s3-protect` | Clumio policy and protection group for the bucket. Apply only after Clumio shows the bucket in its inventory | 00, 10 |
| `12-s3-restore-sg` | Empty bucket in a second Region (restore target) | none |
| `14-s3-guard` | Strict key policy and an explicit-deny key, with one object each | 10 |
| `15-s3-guard-protect` | A second Clumio protection group for the bucket's guard test | 00, 10, 14 |
| `20-rds` | Two small Postgres instances, `aws/rds` and your key | none |
| `21-rds-protect` | Clumio rule and policy for the two databases | 00, 20 |
| `13-rds-subnets-sg`, `22-rds-sg-protect` | Second-Region restore needs: key, subnet group, security group, and the Clumio rule | 20, 21 |
| `30-ec2` | Two small instances, root volume `aws/ebs` and your key | none |
| `31-ec2-protect` | Clumio policy; `scripts/assign-ec2-policy.sh` assigns it to the instances | 00, 30 |

**Other Regions.** `00-connect` connects `ap-southeast-2` only. The cross-Region restores (S3 and RDS into `ap-southeast-1`) ran through a Clumio connection that already existed for that Region. To repeat them, connect the target Region to Clumio first. `12-s3-restore-sg`, `13-rds-subnets-sg` and `22-rds-sg-protect` assume it.

If a wider Clumio tenant rule would claim your databases first, set `before_rule_id` in `21-rds-protect` and `22-rds-sg-protect` to that rule's ID, read from the Clumio API. The default (empty) puts your rule last.

## Capture and restore scripts

Run from the repository root, after the matching folders are applied. All are read-only except the `restore-*` scripts, which ask Clumio to restore into new resources, and `assign-ec2-policy.sh`.

| Script | Does |
|---|---|
| `scripts/record.sh s3`, `record-rds.sh`, `record-ec2.sh` | Save raw AWS and Clumio answers to `evidence/<name>-<time>/` with checksums |
| `scripts/demo-proof.sh`, `show-role.sh`, `show-ec2-snapshots.sh` | Print the proof on screen (read-only) |
| `scripts/restore-s3.sh`, `restore-rds.sh`, `restore-ec2.sh` | Run a restore and save the result |
| `scripts/check-guard.sh` | Read the result of the strict-policy and deny test after its backup runs |
| `scripts/verify-evidence.sh` | Check every evidence folder against its checksums |

## Teardown (order matters; a wrong order leaves backups "in progress")

1. In the Clumio console, Tasks: confirm nothing for your policies is in progress. A person looks.
2. Delete the restored RDS and EC2 instances you created with the restore scripts (check the tag before each delete). Then destroy `31-ec2-protect`, `30-ec2`, `22-rds-sg-protect`, `13-rds-subnets-sg`, `21-rds-protect`, `20-rds`. Confirm no `clumio-airgap-*` snapshot is left.
3. Destroy `15-s3-guard-protect`, `14-s3-guard`, `11-s3-protect`, `12-s3-restore-sg`, `10-s3`. SecureVault copies stay until their retention ends (S3: 30 days at the lowest).
4. `00-connect` last. It has `prevent_destroy`; remove that line on purpose. Stop backups first, and your Clumio tenant must allow deleting connections.
5. Check the account is empty: no `amkcmk-*` buckets, no RDS, no EC2, no `clumio-airgap-*` snapshots. KMS keys wait 7 days before deletion.
