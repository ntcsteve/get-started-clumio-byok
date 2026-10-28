# Experiment E4, Clumio side only: the policy for the two EC2 instances from 30-ec2, with the lowest
# retention Clumio's EC2 policy accepts here (1 day, SecureVault Standard). Creates a Clumio object only;
# no AWS sign-in. The kit has no module for EC2, so the resource is written out.
#
# DECLARED DEVIATION: there is no rule here. Our lab tenant was at Clumio's limit of 25 policy rules
# (error 107 when a rule was tried), and the Terraform provider cannot assign a policy to an EC2 instance
# directly. ../../scripts/assign-ec2-policy.sh assigns this policy to the two instances through the Clumio API instead.
# Retires when: the tenant has a free rule slot, or the provider supports EC2 assignment.
# Credentials: CLUMIO_API_TOKEN and CLUMIO_API_BASE_URL.

provider "clumio" {}

# The instance names come from 30-ec2's outputs, so they are never typed twice.
data "terraform_remote_state" "workload" {
  backend = "local"
  config = {
    path = "${path.module}/../30-ec2/terraform.tfstate"
  }
}

locals {
  instance_names = try(data.terraform_remote_state.workload.outputs.instance_names, []) # Empty until 30-ec2 is applied.
}

# Stops the plan with "AWS connection not found" if 00-connect has not run for this account and Region.
data "clumio_aws_connection" "existing" {
  account_native_id = var.account_id
  aws_region        = var.region

  lifecycle {
    precondition {
      condition     = length(local.instance_names) == 2
      error_message = "30-ec2 has no instances yet. Apply 30-ec2 first, then wait for Clumio to see them."
    }
  }
}

resource "clumio_policy" "ec2" {
  name = "amkcmk-ec2"

  operations {
    type           = "aws_ec2_instance_backup"
    action_setting = "immediate" # The first backup starts when the rule matches an instance.
    slas {
      retention_duration {
        unit  = "days"
        value = 1
      }
      rpo_frequency {
        unit  = "days"
        value = 1
      }
    }
    advanced_settings {
      aws_ec2_instance_backup {
        backup_tier = "standard" # SecureVault Standard
      }
    }
  }

  depends_on = [data.clumio_aws_connection.existing]
}

output "policy_id" {
  value = clumio_policy.ec2.id
}
