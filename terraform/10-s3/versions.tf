terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # Same pin as the kit, so the copied lock file stays valid.
    }
  }
}
