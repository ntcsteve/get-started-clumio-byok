# Experiment E2c: the restore TARGET for a cross-Region restore. One new, empty bucket in Singapore.
# This creates one bucket in a second Region and nothing else there. The Region also holds other
# resources that are not ours, and an RDS
# instance that belong to other work. Clumio never protects this bucket (no group or rule selects it).

locals {
  target_region = "ap-southeast-1" # Singapore. Deliberately not a variable: this is the one place it is allowed.
}

provider "aws" {
  region              = local.target_region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

resource "aws_s3_bucket" "restore_target" {
  bucket        = "amkcmk-restore-${var.account_id}-${local.target_region}"
  force_destroy = true # Teardown must remove the restored test objects.
  tags          = { exp = "amkcmk" }

  lifecycle {
    # Cross-Region is the point of this test. A target in the source Region would prove nothing new.
    precondition {
      condition     = local.target_region != var.region
      error_message = "The restore target must be in a different Region from the source (${var.region})."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "restore_target" {
  bucket                  = aws_s3_bucket.restore_target.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value = aws_s3_bucket.restore_target.id
}

output "target_region" {
  value = local.target_region
}
