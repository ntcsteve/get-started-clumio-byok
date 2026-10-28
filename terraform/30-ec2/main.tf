# Experiment E4, AWS side only: two tiny EC2 instances, one variable (the key of the root volume).
#   amkcmk-ec2-amk  root volume encrypted with the AWS-managed EBS key (no key is named, so AWS uses aws/ebs)
#   amkcmk-ec2-cmk  root volume encrypted with our own customer-managed key
# A boot script writes one known line into /opt/amkcmk/proof.txt on each root volume, so the backup holds
# data and a restore can be compared with a literal. No SSH key, no inbound rule, no extra IAM: nothing
# connects to these instances (the default security group admits only its own members). Clumio's side is 31-ec2-protect.

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # A wrong sign-in stops the run before anything is created.
}

locals {
  tags = { exp = "amkcmk" } # Marks every resource of this experiment.
  instances = {
    amk = { name = "amkcmk-ec2-amk", kms_key_id = null, line = "amkcmk E4 file, root volume key: aws/ebs" }
    cmk = { name = "amkcmk-ec2-cmk", kms_key_id = aws_kms_key.cmk.arn, line = "amkcmk E4 file, root volume key: customer-managed" }
  }
}

# The newest Amazon Linux 2023 image, from AWS's own public parameter.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# The customer-managed key. No key policy is given, so AWS applies its default: the account's IAM policies
# decide who may use it, and Clumio's role gets its access from its own IAM policy.
resource "aws_kms_key" "cmk" {
  description             = "amkcmk experiment E4: customer-managed key for EBS"
  deletion_window_in_days = 7 # The shortest AWS allows, so teardown frees the key quickly.
  tags                    = local.tags
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami           = data.aws_ssm_parameter.ami.value
  instance_type = "t3.micro"

  # No public-IP setting: the default subnet assigns one, and forcing false makes Terraform want to replace
  # the instance. The default security group admits only its own members, so nothing outside can reach it.
  monitoring = false

  metadata_options {
    http_tokens = "required" # IMDSv2 only.
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = each.value.kms_key_id # null means AWS uses the AWS-managed key aws/ebs.
    delete_on_termination = true                  # Teardown must not leave a volume behind.
  }

  # The proof file. printf, not echo, so the bytes are exactly the line plus one newline.
  user_data = <<-EOT
    #!/bin/bash
    mkdir -p /opt/amkcmk
    printf '%s\n' '${each.value.line}' > /opt/amkcmk/proof.txt
    sync
  EOT

  user_data_replace_on_change = true

  tags = merge(local.tags, { Name = each.value.name })
}

output "instance_names" {
  value = [for i in local.instances : i.name]
}

output "instance_ids" {
  value = { for k, i in aws_instance.this : k => i.id }
}

output "root_volume_ids" {
  value = { for k, i in aws_instance.this : k => i.root_block_device[0].volume_id }
}

output "cmk_arn" {
  value = aws_kms_key.cmk.arn
}
