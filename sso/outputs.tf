output "cognito_oidc_client_id" {
  description = "Client ID for the Cognito OIDC application (enter into Cognito)."
  value       = zitadel_application_oidc.cognito.client_id
  sensitive   = true
}

output "cognito_oidc_client_secret" {
  description = "Client secret for the Cognito OIDC application (enter into Cognito)."
  value       = zitadel_application_oidc.cognito.client_secret
  sensitive   = true
}
