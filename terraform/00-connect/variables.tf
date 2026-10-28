variable "account_id" {
  description = "The lab AWS account. The AWS provider refuses to run in any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "Lab Region. Pinned so the experiment stays in one Region."
  type        = string

  validation {
    condition     = var.region == "ap-southeast-2"
    error_message = "This experiment runs in ap-southeast-2 only."
  }
}

variable "workloads" {
  description = "What Clumio may protect here: s3 for E0, rds for E1, ebs (EC2 and EBS) for E4."
  type        = list(string)
  default     = ["s3", "rds", "ebs"]
}
