# Experiment E0, AWS side only: one bucket, two tiny objects, one variable (the key).
#   amk.txt  SSE-KMS with the AWS-managed key aws/s3
#   cmk.txt  SSE-KMS with our own customer-managed key
# Clumio's side is the next folder, 11-s3-protect. It is separate on purpose: Clumio must see the
# bucket in its inventory before it is protected, or the first backup runs on an empty group and
# "succeeds" with nothing in it.

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

locals {
  tags = { exp = "amkcmk" } # Marks every resource of this experiment.
}

# The customer-managed key. No key policy is given, so AWS applies its default: the account's IAM
# policies decide who may use it, and Clumio's role gets its access from its own IAM policy.
resource "aws_kms_key" "cmk" {
  description             = "amkcmk experiment: customer-managed key"
  deletion_window_in_days = 7 # The shortest AWS allows, so teardown frees the key quickly.
  tags                    = local.tags
}

resource "aws_s3_bucket" "test" {
  bucket        = "amkcmk-s3-${var.account_id}-${var.region}"
  force_destroy = true # Teardown must remove the versioned test objects.
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "test" {
  bucket                  = aws_s3_bucket.test.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The kit's S3 policy includes Backtrack, which needs Versioning to have anything to roll back to.
resource "aws_s3_bucket_versioning" "test" {
  bucket = aws_s3_bucket.test.id
  versioning_configuration {
    status = "Enabled"
  }
}

# aws:kms with no key id means S3 uses the AWS-managed key aws/s3.
resource "aws_s3_object" "amk" {
  bucket                 = aws_s3_bucket.test.id
  key                    = "amk.txt"
  content                = "amkcmk E0 object, key: aws/s3\n"
  server_side_encryption = "aws:kms"
  depends_on             = [aws_s3_bucket_versioning.test]
}

resource "aws_s3_object" "cmk" {
  bucket                 = aws_s3_bucket.test.id
  key                    = "cmk.txt"
  content                = "amkcmk E0 object, key: customer-managed\n"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.cmk.arn
  depends_on             = [aws_s3_bucket_versioning.test]
}

output "bucket_name" {
  value = aws_s3_bucket.test.id
}

output "cmk_arn" {
  value = aws_kms_key.cmk.arn
}
