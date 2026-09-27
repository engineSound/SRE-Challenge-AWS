# Persistent layer: resources that survive every environment teardown.
#   1. GitHub Actions -> AWS login via OIDC (no stored AWS keys)
#   2. Secrets in AWS Secrets Manager (the "vault"), read by External Secrets Operator

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "sre-challenge-tfstate-4138fd"
    key          = "persistent/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Layer     = "persistent"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 1. GitHub Actions OIDC
# ---------------------------------------------------------------------------

# Lets AWS trust short-lived identity tokens that GitHub issues to workflow runs.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Only jobs from this repo that run in the named GitHub Environments may assume the role.
data "aws_iam_policy_document" "ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for env in var.environments : "repo:${var.github_repo}:environment:${env}"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "${var.project}-github-ci"
  description          = "Assumed by GitHub Actions via OIDC to verify deployments on EKS"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust.json
  max_session_duration = 3600
}

# CI only needs to locate the clusters. What it may do inside Kubernetes is
# granted separately by an EKS access entry in each environment.
data "aws_iam_policy_document" "ci_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project}-*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "describe-sre-challenge-clusters"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_permissions.json
}

# ---------------------------------------------------------------------------
# 2. Secrets Manager (vault)
# ---------------------------------------------------------------------------

# Grafana admin login: one per environment so preprod and prod never share credentials.
resource "random_password" "grafana_admin" {
  for_each = toset(var.environments)
  length   = 24
  special  = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  for_each                = toset(var.environments)
  name                    = "${var.project}/${each.key}/grafana-admin"
  description             = "Grafana admin login for the ${each.key} cluster"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  for_each  = toset(var.environments)
  secret_id = aws_secretsmanager_secret.grafana_admin[each.key].id
  secret_string = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin[each.key].result
  })
}

# Gmail SMTP login for Alertmanager. Terraform creates only the empty container;
# the value is written once by a person with the AWS CLI, so the Gmail app
# password never appears in code, Git, or Terraform state.
resource "aws_secretsmanager_secret" "alertmanager_smtp" {
  name                    = "${var.project}/shared/alertmanager-smtp"
  description             = "Gmail SMTP for Alertmanager. JSON keys: username, password, to"
  recovery_window_in_days = 7
}
