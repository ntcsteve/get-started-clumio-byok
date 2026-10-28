# Both values come from ../lab.auto.tfvars (linked into this folder).
# This folder has no AWS sign-in, so it cannot check the account itself: the connection and bucket
# lookups below stop the plan if Clumio does not know this account, Region and bucket together.

variable "account_id" {
  description = "The lab AWS account that 00-connect connected."
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
