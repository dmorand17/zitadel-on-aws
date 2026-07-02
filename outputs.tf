output "zitadel_url" {
  description = "Base Zitadel URL."
  value       = "https://${var.domain_name}"
}

output "issuer_url" {
  description = "OIDC issuer URL (enter into Cognito as the OIDC provider issuer)."
  value       = "https://${var.domain_name}"
}

output "console_url" {
  description = "Zitadel admin console URL."
  value       = "https://${var.domain_name}/ui/console"
}

output "discovery_url" {
  description = "OIDC discovery document URL."
  value       = "https://${var.domain_name}/.well-known/openid-configuration"
}

output "admin_credentials_secret_arn" {
  description = "Secrets Manager ARN holding the first-instance admin username/password."
  value       = aws_secretsmanager_secret.admin.arn
}

output "alb_dns_name" {
  description = "ALB DNS name (for the Route53 alias / debugging)."
  value       = aws_lb.this.dns_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint address."
  value       = aws_db_instance.this.address
}
