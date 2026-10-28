# Security

This repository holds a lab proof: Terraform for a test account, scripts that mostly read, and saved evidence. It runs no service.

**Evidence is sanitized.** Account numbers, the Clumio organization ID, access key and principal IDs, the ExternalId and IP addresses were replaced before publishing. See the note at the top of [evidence/INDEX.md](evidence/INDEX.md).

**Never commit state or credentials.** Terraform state (`*.tfstate`) holds the Clumio ExternalId and API token. `.gitignore` excludes state, plans, `.terraform/`, `lab.auto.tfvars` and `.env`. Keep it that way in your fork.

**Run it in a test account.** The Terraform creates billable resources and IAM roles for Clumio. Do not point it at a production account.

**Found a leaked identifier or a mistake?** Open a private security advisory on this repository (Security tab, "Report a vulnerability"). For problems with the Clumio service itself, contact Clumio support.
