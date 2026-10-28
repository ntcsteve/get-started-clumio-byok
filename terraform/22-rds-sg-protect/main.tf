# Experiment E1c, Clumio side only: a rule and policy for the two databases that restore-rds.sh will create
# in SINGAPORE (ap-southeast-1). Creates Clumio objects only; no AWS sign-in, and nothing in Singapore.
# Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL.
#
# Why this exists: a wider tenant rule may claim a restored database and apply another policy. Clumio
# applies the first rule that matches, so ours can be placed ahead of it with before_rule_id.

provider "clumio" {}

# The restored names come from 20-rds, so they are never typed twice.
data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../20-rds/terraform.tfstate"
  }
}

locals {
  target_region = "ap-southeast-1" # Singapore. Deliberately not a variable: this is the one place it is allowed.

  source_database_names   = try(data.terraform_remote_state.workload.outputs.db_identifiers, []) # Empty until 20-rds is applied.
  restored_database_names = [for name in local.source_database_names : "${name}-sg1"]
}

# Stops the plan with "AWS connection not found" if Singapore is not connected for this account.
data "clumio_aws_connection" "singapore" {
  account_native_id = var.account_id
  aws_region        = local.target_region

  lifecycle {
    precondition {
      condition     = length(local.source_database_names) == 2
      error_message = "20-rds has no databases yet."
    }
  }
}

# By name: exactly the two restored names. Lowest retention the kit's module accepts: AWS backup window 1 day,
# SecureVault Standard 1 day, no Archive.
module "rds_protection" {
  source = "git::https://github.com/ntcsteve/get-started-clumio-aws.git//modules/clumio-rds-protection?ref=v1.1.0"

  account_id               = var.account_id
  region                   = local.target_region
  name                     = "amkcmk-rds-sg"
  protect_by               = "name"
  database_names           = local.restored_database_names
  pitr_retention_days      = 1
  standard_retention_days  = 1
  archive_retention_months = 0
  before_rule_id           = var.before_rule_id

  depends_on = [data.clumio_aws_connection.singapore]
}

output "policy_id" {
  value = module.rds_protection.policy_id
}

output "restored_names" {
  value = local.restored_database_names
}
