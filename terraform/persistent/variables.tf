variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "sre-challenge"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the CI role"
  type        = string
  default     = "engineSound/SRE-Challenge-AWS"
}

variable "github_oidc_subject_prefix" {
  description = "Subject prefix GitHub puts in OIDC tokens for this repo (immutable format: owner@ownerID/repo@repoID). Check: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
  default     = "repo:engineSound@35352595/SRE-Challenge-AWS@1391130143"
}

variable "environments" {
  description = "Environments; each must match a GitHub Environment name"
  type        = list(string)
  default     = ["preprod", "prod"]
}
