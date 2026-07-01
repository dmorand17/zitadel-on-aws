variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names and Name tags."
  type        = string
  default     = "keycloak"
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy into."
  type        = string
}

variable "public_subnet_ids" {
  description = "Existing internet-facing subnet IDs for the ALB (>= 2, different AZs)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Provide at least two public subnet IDs in different AZs for the ALB."
  }
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs for Fargate and RDS (>= 2, with egress via NAT or VPC endpoints)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnet IDs in different AZs (RDS subnet group needs 2 AZs)."
  }
}

variable "domain_name" {
  description = "FQDN for Keycloak, e.g. keycloak.example.com. Must be within the Route53 hosted zone."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation and the alias record."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the ALB on HTTPS."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "Provide at least one CIDR block; do not leave the ALB open to 0.0.0.0/0 unintentionally."
  }
}

variable "keycloak_image_tag" {
  description = "Tag of the official quay.io/keycloak/keycloak image."
  type        = string
  default     = "26.0"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine major version."
  type        = string
  default     = "16"
}

variable "realm_name" {
  description = "Name of the Keycloak realm created in the stage-2 apply."
  type        = string
  default     = "demo"
}

variable "cognito_acs_url" {
  description = "Cognito SAML assertion consumer service URL. Placeholder allowed until Cognito exists."
  type        = string
  default     = "https://example.auth.us-east-1.amazoncognito.com/saml2/idpresponse"
}

variable "cognito_sp_entity_id" {
  description = "Cognito SAML service-provider entity ID (urn:amazon:cognito:sp:<user-pool-id>). Placeholder allowed."
  type        = string
  default     = "urn:amazon:cognito:sp:us-east-1_EXAMPLE"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Keycloak container."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags merged into all resources."
  type        = map(string)
  default     = {}
}
