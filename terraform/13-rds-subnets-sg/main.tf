# Experiment E1c, AWS side: what a cross-Region RDS restore into Singapore must name. Clumio fills the
# KMS key, the DB subnet group and the security group from the SOURCE backup unless the request
# overrides them, and those Sydney values do not exist in Singapore (attempts 1 to 3, evidence/INDEX.md).
# This creates ONE resource in Singapore: a DB subnet group of our own, tagged exp=amkcmk. It only reads
# the default VPC, its subnets, its default security group and the AWS-managed RDS key.
# The Region may hold other databases and subnet groups; this folder never names them.

locals {
  target_region = "ap-southeast-1" # Singapore. Deliberately not a variable: this is the one place it is allowed.
}

provider "aws" {
  region              = local.target_region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.default.id
  name   = "default"
}

# Singapore's own AWS-managed RDS key (a different key from Sydney's aws/rds).
data "aws_kms_key" "rds" {
  key_id = "alias/aws/rds"
}

resource "aws_db_subnet_group" "restore_target" {
  name        = "amkcmk-subnets"
  description = "amkcmk experiment: subnets for restored test databases"
  subnet_ids  = data.aws_subnets.default.ids
  tags        = { exp = "amkcmk" }

  lifecycle {
    precondition {
      condition     = local.target_region != var.region && length(data.aws_subnets.default.ids) >= 2
      error_message = "Needs a target Region different from the source, and at least 2 default-VPC subnets."
    }
  }
}

output "subnet_group_name" {
  value = aws_db_subnet_group.restore_target.name
}

output "security_group_id" {
  value = data.aws_security_group.default.id
}

output "kms_key_arn" {
  value = data.aws_kms_key.rds.arn
}
