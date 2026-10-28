# How it works: AMK and CMK with Clumio (ASCII map)

`[P]` proven by AWS or CloudTrail evidence. `[I]` inferred, not proven. Clumio's role means sessions of `amkcmk-ClumioIAMRole-ase-2`. Evidence: see `evidence/INDEX.md` and `PROOF.md`.

## 1. The two key types

```
                    AWS-MANAGED KEY (AMK)             CUSTOMER-MANAGED KEY (CMK)
                    ---------------------             --------------------------
made by             AWS, automatically                us (our Terraform)
name                alias/aws/rds, alias/aws/s3       no alias, tag exp=amkcmk
KeyManager          AWS                               CUSTOMER
key policy          AWS wrote it. Nobody can edit it  AWS default: account root only
                    Any role in the account, but      Our account's IAM policies
                    ONLY through the service          decide who may use it
                    (kms:ViaService)
can be shared       never                             yes, if its policy allows
with another acct
```

## 2. RDS backup: identical for AMK and CMK [P]

```
OUR ACCOUNT                                                  ACCOUNT 222222222222 [I: Commvault's]
-----------------------------------------------------        ----------------------------------
database
  AMK database: encrypted with aws/rds   (f07e156d)
  CMK database: encrypted with our CMK   (c303ff3d)
     |
     | 1. CreateDBSnapshot            (Clumio's role, in our account)
     v
snapshot "to-encrypt"                 same key as the database
     |
     | 2. CopyDBSnapshot  ----------------------------------->  key 32b305a5  (a key that can be shared)
     v
snapshot "encrypted"                  re-locked under key 32b305a5
     |
     | 3. share ONLY this copy  ----------------------------->  the other account can now read the copy
     |                                                              |
     | 4. DeleteDBSnapshot "to-encrypt"                             v
     |                                                          vault copy "clumio-airgap-final-..."
     v
the AMK-encrypted snapshot was NEVER shared (CloudTrail: 0 shares)
```

## 3. RDS restore: the same road back [P]

```
ACCOUNT 222222222222                                         OUR ACCOUNT
--------------------------------                             ------------------------------------------
vault copy "clumio-airgap-final-..."
     |
     | CopyDBSnapshot (Clumio's role) -----------------------> snapshot "restored", encrypted with the
     |                                                         TARGET key (we named none, so the source key:
     |                                                         aws/rds for the AMK db, our CMK for the CMK db)
                                                                   |
                                                                   | RestoreDBInstanceFromDBSnapshot
                                                                   v
                                                              new instance, available, same key as its source
                                                                   |
                                                                   | DeleteDBSnapshot (temporary copies)
```

## 4. S3 backup and restore: AMK object and CMK object in one bucket

```
BACKUP
  amk.txt  (SSE-KMS, aws/s3)  \
                               >--  Clumio's role reads them through S3 [P]  -->  Clumio vault
  cmk.txt  (SSE-KMS, our CMK) /       KMS log: two Decrypt events, 11:36:56,      2 of 2 objects, 70 bytes [P]
                                       one with aws/s3 (amk.txt), one with our     (the two file sizes: 30 + 40)
                                       CMK (cmk.txt), made by role session
                                       daebaksrv-S3Backup via fas.s3.amazonaws.com

RESTORE  (same Region, and Singapore)
  Clumio vault  -->  Clumio writes into the destination bucket  -->  files MATCH byte for byte [P]
                     the copy takes the bucket's default key (AES256), not the source key [P]
                     the source Region's keys are not needed (KMS keys are regional) [P]
```

## 5. Why the AMK is not a blocker

```
The AMK rule:    an AMK-encrypted snapshot cannot be SHARED.            (true, AWS documents it)
Clumio's way:    never share it.
                   open it inside our account (the AMK works there, through RDS),
                   copy it into a NEW box locked with a key that can be shared,
                   share only the new box.
The CMK case:    the same road. The key type does not change the flow.
```

## 6. Who allows what (no key policy was changed) [P]

```
AMK path   key policy (AWS): "any principal in the account, only via rds.<region>"
           + Clumio's IAM role (ClumioKMSPolicy: Decrypt, Encrypt, ReEncrypt*, GenerateDataKey*, DescribeKey)
           + CloudTrail: Clumio's role created a KMS grant on the aws/rds key, through RDS

CMK path   key policy (default): account root, kms:*  ->  the account's IAM decides
           + the same Clumio IAM role
           + the key's grants (6 in the saved list) all belong to the RDS service; none names Clumio
```

## 7. Cross-Region RDS restore: what the request must name [P: attempts 1 to 4]

```
backup (Sydney)                                              destination: Singapore
-------------------------------------------------------      -------------------------------------------
restore request
  names NOTHING   -> Clumio inherits the Sydney values        error 341 "invalid KMS key ID" (Sydney key)
                     (key, subnet group, security group)       then "invalid subnet group 'default'"
  names key + subnet group + security group in Singapore
                  -> Clumio copies the vaulted snapshot  --->  snapshot re-encrypted with the NAMED key
                     into Singapore (a CopyDBSnapshot)         |
                                                              RestoreDBInstanceFromDBSnapshot
                                                               v
                                                           new instance, available, under the NAMED key
```
The key type at restore is the caller's choice. Both databases came up under Singapore's `aws/rds` key because that is the key we named. A Singapore CMK was not tried.

## 8. What is not on the map

RDS rows (the databases were empty), cross-account and "source account lost", scale, a negative control that revokes access on RDS or EC2, a written vendor statement of support, and that `222222222222` is Commvault's own account (strongly hinted: two copies in our account were made by that account with user agent `APN/1.0 Commvault/1.0`).

EC2 and the strict key policy are proven in `PROOF.md` (C11 to C13) but are not drawn on this map.
