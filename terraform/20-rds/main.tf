# Experiment E1, AWS side only: two tiny Postgres instances, one variable (the key).
#   amkcmk-rds-amk  storage encrypted with the AWS-managed key aws/rds (no key id given)
#   amkcmk-rds-cmk  storage encrypted with our own customer-managed key
# Clumio's side is the next folder, 21-rds-protect. Nothing here connects to the databases: an empty
# database is enough to answer "can Clumio back it up at all?". Rows come later, for the restore test.

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

locals {
  tags = { exp = "amkcmk" } # Marks every resource of this experiment.
}

# The customer-managed key. No key policy is given, so AWS applies its default: the account's IAM
# policies decide who may use it. Whether Clumio can use it for RDS is part of what E1 finds out.
resource "aws_kms_key" "cmk" {
  description             = "amkcmk experiment E1: customer-managed key for RDS"
  deletion_window_in_days = 7 # The shortest AWS allows, so teardown frees the key quickly.
  tags                    = local.tags
}

# One shape for both databases, so the key is the only difference.
locals {
  db = {
    amk = { identifier = "amkcmk-rds-amk", kms_key_id = null }
    cmk = { identifier = "amkcmk-rds-cmk", kms_key_id = aws_kms_key.cmk.arn }
  }
}

resource "aws_db_instance" "this" {
  for_each = local.db

  identifier     = each.value.identifier
  engine         = "postgres" # No engine_version: AWS picks its current default. record-rds.sh records which.
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_encrypted = true
  kms_key_id        = each.value.kms_key_id # null means AWS uses the AWS-managed key aws/rds.

  username                    = "labadmin"
  manage_master_user_password = true # RDS keeps the password in Secrets Manager: it never enters our state.

  publicly_accessible        = false
  auto_minor_version_upgrade = false
  deletion_protection        = false
  skip_final_snapshot        = true # Teardown must not leave a final snapshot behind.
  apply_immediately          = true

  # Clumio's policy sets the AWS backup window to 1 day (pitr_retention_days). Creating the databases
  # with 1 already means Clumio finds nothing to change, so it never has to restart an instance.
  backup_retention_period = 1

  tags = local.tags
}

output "db_identifiers" {
  value = [for d in aws_db_instance.this : d.identifier]
}

output "cmk_arn" {
  value = aws_kms_key.cmk.arn
}
