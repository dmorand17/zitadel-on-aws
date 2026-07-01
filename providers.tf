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
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed-by = "terraform"
      project    = "keycloak-on-aws"
    }
  }
}

# Configured with the ALB endpoint + bootstrap admin creds. Only usable in the
# stage-2 apply, after the Fargate service is healthy. See keycloak.tf / README.
provider "keycloak" {
  client_id = "admin-cli"
  username  = local.keycloak_admin_username
  password  = random_password.keycloak_admin.result
  url       = "https://${var.domain_name}"
}
