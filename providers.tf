terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed-by = "terraform"
      project    = "zitadel-on-aws"
    }
  }
}

# Configured against the ALB endpoint. Only usable in the stage-2 apply, after
# the Fargate service is healthy AND a service-user key exists. Authentication
# details (jwt_profile_file / PAT) are finalized in zitadel.tf / README.
# Left with the domain + insecure=false; credentials supplied at stage-2.
provider "zitadel" {
  domain           = var.domain_name
  insecure         = "false"
  port             = "443"
  jwt_profile_file = "zitadel-admin-sa.json"
}
