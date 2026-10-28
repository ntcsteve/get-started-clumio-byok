# Experiment E1, Clumio side only: protect the two databases from 20-rds, by name, with the lowest
# retention the kit's RDS module accepts. Creates Clumio objects only; no AWS sign-in.
# Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL (your Clumio environment file).

provider "clumio" {}

# The database names come from 20-rds's outputs, so they are never typed twice.
data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../20-rds/terraform.tfstate"
  }
}

locals {
  source_database_names = try(data.terraform_remote_state.workload.outputs.db_identifiers, []) # Empty until 20-rds is applied.

  # The RDS restore test (scripts/restore-rds.sh) creates these two databases. A wider tenant rule could
  # claim any database in the account, so our rule names them too (and var.before_rule_id puts it ahead
  # of that rule), so no other policy reaches a test database. Delete these names when the restore test is torn down.
  restored_database_names = [for name in local.source_database_names : "${name}-r1"]
  database_names          = concat(local.source_database_names, local.restored_database_names)

}

# Stops the plan with "AWS connection not found" if 00-connect has not run for this account and Region.
data "clumio_aws_connection" "existing" {
  account_native_id = var.account_id
  aws_region        = var.region

  lifecycle {
    precondition {
      condition     = length(local.source_database_names) == 2
      error_message = "20-rds has no databases yet. Apply 20-rds first, then wait for Clumio to see them."
    }
  }
}

# By name: exactly these two identifiers (the kit's rule also stays inside this account and Region).
# Retention, the lowest the module accepts: AWS PITR window 1 day, SecureVault Standard 1 day, no Archive.
module "rds_protection" {
  source = "git::https://github.com/ntcsteve/get-started-clumio-aws.git//modules/clumio-rds-protection?ref=v1.1.0"

  account_id               = var.account_id
  region                   = var.region
  name                     = "amkcmk-rds"
  protect_by               = "name"
  database_names           = local.database_names
  pitr_retention_days      = 1
  standard_retention_days  = 1
  archive_retention_months = 0
  before_rule_id           = var.before_rule_id

  depends_on = [data.clumio_aws_connection.existing]
}

output "policy_id" {
  value = module.rds_protection.policy_id
}

output "rule_id" {
  value = module.rds_protection.rule_id
}
