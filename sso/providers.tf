terraform {
  required_version = "~> 1.15"

  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.0"
    }
  }

  # Empty S3 backend — configured per environment via `-backend-config`.
  # See envs/<env>/backend.config for the bucket/key/region values.
  backend "s3" {}
}

# Configured against the running Zitadel service. Requires a service-user JSON
# key (jwt_profile_file) created after stage 1 is healthy — see README.
provider "zitadel" {
  domain           = var.domain_name
  insecure         = "false"
  port             = "443"
  jwt_profile_file = var.jwt_profile_file
}
