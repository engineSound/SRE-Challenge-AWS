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

variable "environments" {
  description = "Environments; each must match a GitHub Environment name"
  type        = list(string)
  default     = ["preprod", "prod"]
}
