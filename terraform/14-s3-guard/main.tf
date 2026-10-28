# Experiment E3, AWS side only: does Clumio still back up under a STRICT key policy, and does an explicit
# deny stop it visibly? Reuses the bucket from 10-s3 and its existing daily Clumio protection group, so
# there is nothing to add on the Clumio side: the next daily backup picks the two new objects up.
#
#   allowed.txt  key policy names Clumio's role explicitly; account root has NO use of the key through IAM
#   denied.txt   key policy explicitly denies Clumio's role
# Both keys keep account root's admin actions (so we cannot lock ourselves out) and let our own Terraform
# upload, through S3 only. Neither key delegates use of the key to IAM policies.

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

# The bucket comes from 10-s3's outputs, so it is never typed twice.
data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../10-s3/terraform.tfstate"
  }
}

locals {
  bucket_name = try(data.terraform_remote_state.workload.outputs.bucket_name, "") # Empty until 10-s3 is applied.
  account_arn = "arn:aws:iam::${var.account_id}:root"
  s3_service  = "s3.${var.region}.amazonaws.com"
  tags        = { exp = "amkcmk" }
}

# Clumio's role, created by 00-connect. The plan stops here if it does not exist.
data "aws_iam_role" "clumio" {
  name = "amkcmk-ClumioIAMRole-ase-2"

  lifecycle {
    postcondition {
      condition     = local.bucket_name != ""
      error_message = "10-s3 has no bucket yet. Apply 10-s3 first."
    }
  }
}

# Statements both keys share. Root has administration but no use of the key, and a narrow upload right.
data "aws_iam_policy_document" "common" {
  statement {
    sid       = "AdministerButDoNotUse"
    effect    = "Allow"
    actions   = ["kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_arn]
    }
  }
  statement {
    sid       = "UploadThroughS3Only"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Encrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.s3_service]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }
}

data "aws_iam_policy_document" "hardened" {
  source_policy_documents = [data.aws_iam_policy_document.common.json]
  statement {
    sid       = "ClumioRoleMayDecryptThroughS3"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.clumio.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.s3_service]
    }
  }
}

data "aws_iam_policy_document" "denied" {
  source_policy_documents = [data.aws_iam_policy_document.common.json]
  statement {
    sid       = "ClumioRoleIsDenied"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.clumio.arn]
    }
  }
}

resource "aws_kms_key" "hardened" {
  description             = "amkcmk E3: strict key policy, Clumio role named explicitly"
  policy                  = data.aws_iam_policy_document.hardened.json
  deletion_window_in_days = 7 # The shortest AWS allows, so teardown frees the key quickly.
  tags                    = local.tags
}

resource "aws_kms_key" "denied" {
  description             = "amkcmk E3: strict key policy, Clumio role explicitly denied"
  policy                  = data.aws_iam_policy_document.denied.json
  deletion_window_in_days = 7
  tags                    = local.tags
}

resource "aws_s3_object" "allowed" {
  bucket                 = local.bucket_name
  key                    = "allowed.txt"
  content                = "amkcmk E3 object, key: strict policy, Clumio role allowed\n"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.hardened.arn
}

resource "aws_s3_object" "denied" {
  bucket                 = local.bucket_name
  key                    = "denied.txt"
  content                = "amkcmk E3 object, key: strict policy, Clumio role denied\n"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.denied.arn
}

output "hardened_key_arn" {
  value = aws_kms_key.hardened.arn
}

output "denied_key_arn" {
  value = aws_kms_key.denied.arn
}
