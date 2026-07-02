# STAGE-2 RESOURCES.
# These require the Zitadel service to be running and reachable at
# https://<domain_name> AND a service-user key file (zitadel-admin-sa.json)
# present for the provider (see README "Two-stage apply"). Apply infra first,
# then apply these:
#   terraform apply                                        # stage 1
#   terraform apply -target=zitadel_project.this \
#                   -target=zitadel_application_oidc.cognito   # stage 2

resource "zitadel_project" "this" {
  name = var.project_name
}

# OIDC application representing the external Cognito User Pool. Cognito uses the
# authorization-code flow with a confidential (client-secret) web app.
resource "zitadel_application_oidc" "cognito" {
  project_id = zitadel_project.this.id
  name       = "cognito"

  redirect_uris    = [var.cognito_callback_url]
  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
}

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
