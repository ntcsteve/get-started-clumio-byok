# Experiment E0, Clumio side only: protect the test bucket from 10-s3, by name, with the lowest
# retention the kit's S3 module accepts. Creates Clumio objects only; no AWS sign-in.
# Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL (your Clumio environment file).

provider "clumio" {}

# The bucket name comes from 10-s3's outputs, so it is never typed twice.
data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../10-s3/terraform.tfstate"
  }
}

locals {
  bucket_name = try(data.terraform_remote_state.workload.outputs.bucket_name, "") # Empty until 10-s3 is applied.
}

# Stops the plan with "AWS connection not found" if 00-connect has not run for this account and Region.
data "clumio_aws_connection" "existing" {
  account_native_id = var.account_id
  aws_region        = var.region

  lifecycle {
    precondition {
      condition     = local.bucket_name != ""
      error_message = "10-s3 has no bucket yet. Apply 10-s3 first, then wait for Clumio to see the bucket."
    }
  }
}

# By name, not by tag: the module looks the bucket up in Clumio and stops the plan if Clumio cannot
# see it yet. That wait is the gate that prevents a backup of an empty group.
# Retention: SecureVault 30 days (Clumio's S3 minimum is one month), Backtrack 1 month.
module "s3_protection" {
  source = "git::https://github.com/ntcsteve/get-started-clumio-aws.git//modules/clumio-s3-protection?ref=v1.1.0"

  account_id                 = var.account_id
  region                     = var.region
  name                       = "amkcmk-s3"
  protect_by                 = "name"
  bucket_names               = [local.bucket_name]
  standard_retention_days    = 30
  backtrack_retention_months = 1

  depends_on = [data.clumio_aws_connection.existing]
}

output "protection_group_id" {
  value = module.s3_protection.protection_group_id
}
