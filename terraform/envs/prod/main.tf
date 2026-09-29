# Prod environment: the shared environment module with prod's settings.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "sre-challenge-tfstate-4138fd"
    key          = "envs/prod/terraform.tfstate"
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
      Environment = "prod"
      Layer       = "environment"
      ManagedBy   = "terraform"
    }
  }
}

module "environment" {
  source = "../../modules/environment"

  environment        = "prod"
  vpc_cidr           = "10.10.0.0/16" # preprod will use 10.20.0.0/16
  azs                = ["us-east-1a", "us-east-1b"]
  kubernetes_version = "1.36"

  node_instance_type = "t3.medium"
  node_count         = 2
  node_max_count     = 3

  admin_user_name = "Design_one"
  ci_role_name    = "sre-challenge-github-ci"
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
