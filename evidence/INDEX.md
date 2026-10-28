# Evidence index

> **About these files.** They are the captures from the lab run, with identifiers replaced so the repo can be public:
> account numbers (`111111111111` is the lab account, `222222222222` the account Clumio copies RDS snapshots into,
> `333333333333` Clumio's principal), the Clumio organization ID, access key and principal IDs, the ExternalId, source
> and public IP addresses. Lists that returned every asset the Clumio tenant could see were cut to the `amkcmk` items,
> and CloudTrail events that belong to another project were removed. The checksums were recomputed after this, so
> `scripts/verify-evidence.sh` proves these files are unchanged since this repo was built, not since the original capture.
> One Clumio export that was saved gzip-compressed is stored as plain text. Role-name suffixes (UUIDs) were replaced, and STS session tokens are `REDACTED`.
> Key IDs, key policies, aliases, `KeyManager` values, task IDs, times and API results are as captured.

Read this first. Tool versions and who ran it: `PROVENANCE.txt`. Integrity of every folder: `../scripts/verify-evidence.sh`. The claim-by-claim proof, with the commands to check it yourself, is `../docs/PROOF.md`. Each folder holds raw output and a `_sha256.txt` manifest (verify with `shasum -a 256 -c _sha256.txt` from inside the folder).

| Folder | What it proves | Result |
|---|---|---|
| `s3-20261025T110657Z` | Foundation F2: amk.txt is `aws/s3` (AWS-managed), cmk.txt is our key (customer-managed). Before Clumio. This bucket was later destroyed (F4) and re-created | SETUP OK |
| `s3-20261025T112942Z` | Same proof after the bucket was re-created (the CMK is a new key) | SETUP OK |
| `s3-20261025T113231Z` | Clumio saw the bucket; first backup not started yet | 0 backups (expected) |
| `s3-20261025T113828Z` | E0: Clumio backed up both objects. 2 of 2, 0 failed, 70 bytes | PASS |
| `e2a-20261025T115029Z` | E2a: restore into the same bucket, same Region. Both files match | PASS |
| `e2c-20261025T120423Z` | E2c: restore into a new bucket in Singapore. Both files match | PASS |
| `s3-20261025T130001Z` | Skeptic proof for S3: alias `alias/aws/s3` and `KeyManager AWS` for amk.txt, `KeyManager CUSTOMER` + tag `exp=amkcmk` for cmk.txt, and the `aws/s3` key policy read from AWS (`policy-aws-managed-key.json`) | SETUP OK |
| `rds-20261025T125926Z` | E1 skeptic proof for RDS: alias `alias/aws/rds` + `KeyManager AWS` for the AMK database, `CUSTOMER` + tag for the CMK database, the `aws/rds` key policy, every Clumio snapshot with its key, and who each is shared with. In progress: the SecureVault backups had not finished | SETUP OK, backups pending |
| `rds-cloudtrail-20261025T131205Z` | CloudTrail, the API log of how Clumio handled the RDS snapshots in our account: `CreateDBSnapshot` x2, `CopyDBSnapshot` x2 (to a key in account 222222222222), `ModifyDBSnapshotAttribute` x2 (share the encrypted copy only), `DeleteDBSnapshot` x2. All by role `amkcmk-ClumioIAMRole-ase-2`. 0 shares of the `aws/rds` snapshot. Event history is kept only 90 days, so this is the durable copy | PROVEN |
| `rds-20261025T131402Z` | **Canonical complete E1 capture**: everything in `rds-20261025T130158Z` plus the CloudTrail files, captured by the script itself (create / copy / share / delete = 2/2/2/2) | SETUP OK, 1 backup each |
| `rds-restore-20261025T131639Z` | E1b: RDS restore of both backups into new instances; restored instance, its key and alias, Clumio tasks, CloudTrail of the restore path | PASS |
| `review-fixes-20261025T134621Z` | Evidence behind the independent review's findings: S3 KMS `Decrypt` events by Clumio's role with `aws/s3` and with our CMK; the two `CopyDBSnapshot` calls made by account 222222222222 (user agent Commvault); both CMK key policies and grants; the Clumio role's inline and attached policies; the full `describe-key` for all four keys | PROVEN |
| `kms-cloudtrail-20261025T132702Z` | KMS events on the `aws/rds` and `aws/s3` keys found by `ResourceName`. The `aws/rds` file holds the Clumio `CreateGrant`. The `aws/s3` file holds only our own read calls because that search does not index the S3 `Decrypt` events; those are in `review-fixes-...` | PARTLY SUPERSEDED |
| `review2-fixes-20261025T135941Z` | Evidence behind the second review: the Clumio role's trust policy (the account that may assume it) and the AssumeRole events, the `CreateGrant` events on the RDS CMK with who caused them, the absence of `PutKeyPolicy` events, and the recorded parameters of the copies made by `222222222222` (hidden by AWS) | PROVEN |
| `s3-20261025T135207Z`, `rds-20261025T135225Z` | Regression runs of the record scripts after they began saving the full `describe-key` response | SETUP OK |
| `rds-restore-sg-20261025T215531Z` | E1c attempt 1, RDS restore into Singapore naming no key or network: HTTP 504, Clumio error 397 (gateway). Nothing was created | FAILED, transient |
| `rds-restore-sg-20261025T215749Z` | E1c attempt 2, same request: HTTP 400, error 341 `invalid KMS key ID`, naming the **Sydney** `aws/rds` key. Clumio defaults the restore key to the source key | FINDING |
| `rds-restore-sg-20261025T215812Z` | E1c attempt 3, naming Singapore's `aws/rds` key: the key was accepted; HTTP 400, error 341 `invalid subnet group name 'default'`. Clumio defaults the subnet group to the source's | FINDING |
| `rds-restore-sg-20261025T220728Z` | E1c attempt 4, RDS restore into Singapore naming the Singapore `aws/rds` key, our subnet group `amkcmk-subnets` and the default security group: both tasks completed; both instances available and encrypted under the Singapore `aws/rds` key; CloudTrail of the restore path in `ap-southeast-1` | PASS |
| `role-view-20261025T235310Z` | What Clumio's role may do: trust policy (single named Clumio role, ExternalId required, value not stored in the view), permissions by service with account-scoped vs wildcard counts, the delete and modify actions with their scope, KMS actions, and the named sessions seen in CloudTrail (179 AssumeRole calls in 48h from one account, 11 session names). Raw policies included | PROVEN |
| `guard-20261026T062717Z` | E3 guard test, first read: the second group's backup (00:20 UTC) held 4 objects and not the two guard objects; no `Decrypt` on either guard key. INCONCLUSIVE: the objects were newer than Clumio's last daily S3 inventory | INCONCLUSIVE, rerun after the next daily backup |
| `ec2-assign-assign-20261026T083007Z` | the direct policy assignment of `amkcmk-ec2` to the two test instances through the Clumio API (request, task 4047397247, the policy on each instance after) | PASS |
| `ec2-20261026T090741Z` | E4 backup evidence: root volume keys (aws/ebs and our CMK), the `aws/ebs` key policy, Clumio's snapshots, Clumio backup records and tasks | SETUP OK, 1 backup each |
| `ec2-20261026T090648Z` | the first capture of the same run, with four Clumio calls refused (HTTP 400: wrong filter names). Kept as evidence of the fix | superseded |
| `ec2-restore-20261026T091033Z` | E4b: restore with no key named. Both instances running; both root volumes `Encrypted false` | FINDING |
| `ec2-restore-20261026T091706Z` | E4c: restore naming each source key. Both root volumes encrypted: `aws/ebs` and our CMK | PASS |
| `guard-20261027T064458Z` | E3 result: the hardened key's Decrypt by Clumio's role, and Clumio's own list of the one object it failed (explicit Deny) | PASS |
| `rds-20261025T124520Z`, `rds-20261025T12*` (earlier runs) | Earlier captures of the same run, before sharing happened | superseded |

**Why the key proof is strong (for skeptics).** It rests on facts AWS states and we cannot set: `KeyManager`, the reserved alias `alias/aws/<service>`, and the key policy AWS wrote. The customer-managed key also carries the tag our Terraform put on it. Each fact comes from a different AWS call, saved raw with a checksum.

The canonical E0 proof is `s3-20261025T113828Z`. The canonical E1 proof is `rds-20261025T131402Z` (both RDS backups complete, CloudTrail captured; the earlier `rds-20261025T130158Z` has the same backup data; Clumio's backup record carries `kms_key_native_id` for each database). The claim-by-claim proof is `../docs/PROOF.md`.

## Labels in the folder table

`F0` to `F4`: the foundation test, AWS only, before Clumio. `E0`: S3 backup. `E1`: RDS backup (`E1b` restore in the same Region, `E1c` restore into another Region). `E2a` and `E2c`: S3 restore into the same bucket and into a new bucket in another Region. `E3`: the strict key policy and explicit Deny test. `E4`: EC2 backup (`E4b` restore naming no key, `E4c` restore naming the source key). Empty `.err` files are valid captures: the command wrote nothing to standard error.

## Root hash (store it outside this folder)

`scripts/verify-evidence.sh` prints one hash over all manifests. Record it somewhere you control; if a manifest is regenerated or a folder is added, the hash changes.

## Task IDs: the API and the Clumio console show different levels

A restore creates a parent task and per-asset child tasks. The API returns the parent ID; the console task page for an S3 restore shows the child. Both completed. Example, the S3 restore into Singapore: API `4043685609` (`protection_group_restore`, 12:04:51 to 12:08:01 UTC) and console `4043686119` (`protection_group_s3_asset_restore`, 12:05:52 to 12:08:00 UTC). The console page reads: restored 2 object(s) in total of 70 byte(s), failed to restore 0, from the Sydney bucket to the Singapore bucket.

## Reading the Clumio console's RDS restore pages

The task pages for the two RDS restores (Sydney, task 4043872121; Singapore, task 4045261351) show the same seven steps: prepare the vaulted snapshot (`clumio-airgap-final-...`), copy it into our account and Region, restore the instance, delete the temporary snapshot. Each took 11 minutes. One display quirk: the Singapore page's **Source** line reads `.../ap-southeast-1`, which is the Region the task ran in, not the Region of the source database. Both tasks name the **same** source resource (`primary_entity.id` `e9d53670-...`, the Sydney `amkcmk-rds-amk`), and Clumio's inventory holds no `amkcmk-rds-amk` in Singapore.
