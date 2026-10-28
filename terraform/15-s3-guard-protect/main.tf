# Experiment E3, Clumio side only: a SECOND protection group on the bucket from 10-s3, so Clumio backs the
# bucket up now, including the two guard-test objects from 14-s3-guard, instead of at tomorrow's scheduled
# backup. A new group starts its first backup when its policy is assigned. Creates Clumio objects only.
# Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL.

provider "clumio" {}

data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../10-s3/terraform.tfstate"
  }
}

# The guard objects must exist first, or this backup would prove nothing.
data "terraform_remote_state" "guard" {
  backend = "local"
  config = {
    path = "${path.module}/../14-s3-guard/terraform.tfstate"
  }
}

locals {
  bucket_name = try(data.terraform_remote_state.workload.outputs.bucket_name, "") # Empty until 10-s3 is applied.
  guard_ready = try(data.terraform_remote_state.guard.outputs.hardened_key_arn, "") != ""
}

data "clumio_aws_connection" "existing" {
  account_native_id = var.account_id
  aws_region        = var.region

  lifecycle {
    precondition {
      condition     = local.bucket_name != "" && local.guard_ready
      error_message = "Apply 10-s3 and 14-s3-guard first: the guard objects must exist before this backup runs."
    }
  }
}

# By name: the module looks the bucket up in Clumio and stops the plan if Clumio cannot see it.
# Retention: SecureVault 30 days (Clumio's S3 minimum), Backtrack 1 month.
module "s3_protection" {
  source = "git::https://github.com/ntcsteve/get-started-clumio-aws.git//modules/clumio-s3-protection?ref=v1.1.0"

  account_id                 = var.account_id
  region                     = var.region
  name                       = "amkcmk-guard"
  protect_by                 = "name"
  bucket_names               = [local.bucket_name]
  standard_retention_days    = 30
  backtrack_retention_months = 1

  depends_on = [data.clumio_aws_connection.existing]
}

output "protection_group_id" {
  value = module.s3_protection.protection_group_id
}
