variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names and Name tags."
  type        = string
  default     = "zitadel"
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
  description = "FQDN for Zitadel, e.g. id.example.com. Must be within the Route53 hosted zone."
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

variable "zitadel_image_tag" {
  description = "Tag of the official ghcr.io/zitadel/zitadel image."
  type        = string
  default     = "v2.71.12"
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

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Zitadel container."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags merged into all resources."
  type        = map(string)
  default     = {}
}
