# Connect the lab account in ap-southeast-2 to Clumio. Uses the kit's IAM module, so there is no
# Clumio logic to maintain here. Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL (your Clumio environment file).

provider "clumio" {}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

resource "clumio_aws_connection" "this" {
  account_native_id = var.account_id
  aws_region        = var.region
  description       = "AMK vs CMK experiment (get-started-clumio-byok)"

  lifecycle {
    # A destroy deletes Clumio's IAM first, then the connection. If Clumio refuses the second part,
    # backups stop. Teardown (terraform/README.md) removes this line on purpose, last.
    prevent_destroy = false # Teardown 2026-10-28: removed on purpose, last, as planned.
  }
}

module "clumio_iam" {
  source     = "git::https://github.com/ntcsteve/get-started-clumio-aws.git//modules/clumio-account-iam?ref=v1.1.0"
  connection = clumio_aws_connection.this
  workloads  = var.workloads

  # IAM names are global to the account, and another Region may already have Clumio roles here. The prefix
  # makes every name we create distinct, so an apply cannot collide with them, and it marks ours.
  iam_prefix = "amkcmk"
}
