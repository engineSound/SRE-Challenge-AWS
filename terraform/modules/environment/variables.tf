variable "project" {
  description = "Name prefix shared by all environments"
  type        = string
  default     = "sre-challenge"
}

variable "environment" {
  description = "Environment name, e.g. prod or preprod"
  type        = string
}

variable "vpc_cidr" {
  description = "IP range for this environment's VPC; must not overlap other environments"
  type        = string
}

variable "azs" {
  description = "Two availability zones to spread subnets and nodes across"
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two availability zones are expected."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Number of worker nodes (desired and minimum)"
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Upper bound for the node group"
  type        = number
  default     = 3
}

variable "admin_user_name" {
  description = "IAM user granted cluster-admin through an EKS access entry"
  type        = string
}

variable "ci_role_name" {
  description = "IAM role used by GitHub Actions (from the persistent layer); granted read-only access"
  type        = string
}
