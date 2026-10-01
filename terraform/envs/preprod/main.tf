# Preprod environment: the same module as prod with preprod's settings
# (its own VPC, cluster, ArgoCD and monitoring — fully isolated from prod).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }

  backend "s3" {
    bucket       = "sre-challenge-tfstate-4138fd"
    key          = "envs/preprod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "sre-challenge"
      Environment = "preprod"
      Layer       = "environment"
      ManagedBy   = "terraform"
    }
  }
}

# Helm talks to the cluster this configuration creates, authenticating with
# a short-lived token from the AWS CLI (same login that runs Terraform).
provider "helm" {
  kubernetes = {
    host                   = module.environment.cluster_endpoint
    cluster_ca_certificate = base64decode(module.environment.cluster_ca_certificate)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.environment.cluster_name, "--region", "us-east-1"]
    }
  }
}

module "environment" {
  source = "../../modules/environment"

  environment        = "preprod"
  vpc_cidr           = "10.20.0.0/16" # prod uses 10.10.0.0/16; never overlap
  azs                = ["us-east-1a", "us-east-1b"]
  kubernetes_version = "1.36"

  node_instance_type = "t3.medium"
  node_count         = 3 # 17 pods per t3.medium; 3 nodes leave room for the platform + rolling updates
  node_max_count     = 4

  admin_user_name = "Design_one"
  ci_role_name    = "sre-challenge-github-ci"

  git_repo_url              = "https://github.com/engineSound/SRE-Challenge-AWS.git"
  git_revision              = "main"
  argocd_chart_version      = "10.9.4" # ArgoCD v3.5.3
  argocd_apps_chart_version = "2.0.6"
}

output "cluster_name" {
  value = module.environment.cluster_name
}

output "kubeconfig_command" {
  value = module.environment.kubeconfig_command
}

output "nat_public_ip" {
  value = module.environment.nat_public_ip
}
