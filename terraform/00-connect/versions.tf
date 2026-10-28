# Same pins as the kit's step 1, so the copied lock file stays valid.
terraform {
  required_version = ">= 1.5"
  required_providers {
    clumio = {
      source  = "clumio-code/clumio"
      version = ">= 0.24.0, < 0.25.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
